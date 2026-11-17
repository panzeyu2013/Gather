#!/usr/bin/env python3
"""perf-sqlite-bench.py — 合成照片库上的热点 SQL 基准（性能审计 R3 开发工具，非 CI 门禁）。

用途
  - 从 SchemaCurrent 的**真实 DDL** 建库（55 表 / 86 显式索引 / 81 外键，与生产同构），
    用固定 seed 生成确定性的合成数据（默认 5k 照片），对热点查询跑 warm+median 计时，
    并打印 EXPLAIN QUERY PLAN。
  - --compare 额外跑「改动前 SQL 变体」，输出 A/B 与加速比（用于 DISTINCT / 分块 prepare
    这类纯 SQL/访问路径改动的前后证据）。
  - 只依赖 python3 标准库（sqlite3/tempfile/statistics），Linux/macOS 均可跑。

用法
  python3 scripts/perf-sqlite-bench.py                 # 默认 5000 张照片
  python3 scripts/perf-sqlite-bench.py --rows 20000    # 放大到 2 万张
  python3 scripts/perf-sqlite-bench.py --compare       # A/B：旧 SQL vs 新 SQL
  python3 scripts/perf-sqlite-bench.py --repeats 31 --json   # 原始数字
  python3 scripts/perf-sqlite-bench.py --keep-db /tmp/gather-bench.db  # 保留建好的库

确定性说明
  - 数据由 --seed（默认 42）决定；同 --rows/--seed 的数据内容与 EXPLAIN 输出可复现。
  - 计时是墙钟中位数（--repeats，默认 15），受机器/IO 影响，只用于 A/B 相对比较。
  - 脚本不写仓库内文件：默认在系统临时目录建库并在结束时删除（--keep-db 可保留）。
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sqlite3
import statistics
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DB_DIR = REPO_ROOT / "desktop/native/gather-core/Sources/GatherPersistence/Database"
DDL_FILES = [
    DB_DIR / "Schema/SchemaCurrent+DDLCore.swift",
    DB_DIR / "Schema/SchemaCurrent+DDLDomain.swift",
    DB_DIR / "Schema/SchemaCurrent+DDLIndexes.swift",
    DB_DIR / "SchemaCurrent.swift",
    DB_DIR / "Schema/SchemaCurrent+DDLWorkbench.swift",
]
# 生产 createSQL 的拼接顺序（SchemaCurrent.swift:167-171）：
#   ddlCore + ddlDomain + ddlIndexes + addendumDDL + workbenchDDL
EXPECTED_TABLES, EXPECTED_INDEXES, EXPECTED_FKS = 55, 86, 81
ID_TIME = "2026-11-17T00:00:00.000Z"


def session_count(rows: int) -> int:
    """合成会话数：默认每会话约 5000 张（>=2），单会话规模足够触发列表排序成本。"""
    return max(2, rows // 5000)

MULTILINE = re.compile(r'"""\n(.*?)\n\s*"""', re.DOTALL)


def extract_ddl() -> str:
    parts = []
    for path in DDL_FILES:
        text = path.read_text(encoding="utf-8")
        m = MULTILINE.search(text)
        if not m:
            raise SystemExit(f"perf-sqlite-bench: no multiline DDL literal in {path}")
        parts.append(m.group(1))
    return "\n".join(parts)


def schema_facts(conn: sqlite3.Connection) -> tuple[int, int, int]:
    q = lambda sql: conn.execute(sql).fetchall()
    tables = [r[0] for r in q("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    indexes = q("SELECT count(*) FROM sqlite_master WHERE type='index' AND sql IS NOT NULL")[0][0]
    fks = sum(len(q(f"PRAGMA foreign_key_list({t})")) for t in tables)
    return len(tables), indexes, fks


def parse_checks(ddl: str) -> dict[str, dict[str, list]]:
    """从 DDL 里提取 CHECK (col IN (...)) 允许值：合成数据不能违反 CHECK。"""
    allowed: dict[str, dict[str, list]] = {}
    for m in re.finditer(r"CREATE TABLE (\w+) \((.*?)\n\s*\);", ddl, re.DOTALL):
        table, body = m.group(1), m.group(2)
        cols: dict[str, list] = {}
        for cm in re.finditer(r"CHECK \(\s*(\w+)\s+IN\s+\(([^)]*)\)\s*\)", body):
            col, raw = cm.group(1), cm.group(2)
            vals = []
            for tok in raw.split(","):
                tok = tok.strip()
                if tok.startswith("'"):
                    vals.append(tok.strip("'"))
                else:
                    try:
                        vals.append(int(tok))
                    except ValueError:
                        pass
            if vals:
                cols[col] = vals
        allowed[table] = cols
    return allowed


def table_columns(conn: sqlite3.Connection, table: str):
    return conn.execute(f"PRAGMA table_info({table})").fetchall()  # (cid,name,type,notnull,dflt,pk)


class Seeder:
    def __init__(self, conn: sqlite3.Connection, rows: int, seed: int):
        self.conn = conn
        self.rows = rows
        self.rng = random.Random(seed)
        self.allowed = parse_checks(extract_ddl())

    # ---- 通用行构建：显式语义列 + 其余 NOT NULL 无默认列按类型补 ----
    def insert(self, table: str, count: int, overrides):
        cols = table_columns(self.conn, table)
        auto_pk = None
        if len([c for c in cols if c[5] == 1]) == 1:
            pk = [c for c in cols if c[5] == 1][0]
            if pk[2].strip().upper() == "INTEGER":
                auto_pk = pk[1]
        names, rows = [], []
        sample = overrides(0) if count else {}
        generic_cols = []
        for cid, name, ctype, notnull, dflt, pk in cols:
            if name == auto_pk:
                continue
            if name in sample:
                names.append(name)
            elif notnull and dflt is None:
                generic_cols.append((name, (ctype or "").upper(), pk))
                names.append(name)
        # 列集合：显式列 + 通用列（顺序沿用 table_info）
        names = []
        explicit = set(sample.keys())
        for cid, name, ctype, notnull, dflt, pk in cols:
            if name == auto_pk:
                continue
            if name in explicit or (notnull and dflt is None):
                names.append(name)
        allowed = self.allowed.get(table, {})
        for i in range(count):
            sem = overrides(i)
            row = []
            for name in names:
                if name in sem:
                    row.append(sem[name])
                else:
                    ctype = next(c[2] for c in cols if c[1] == name).upper()
                    row.append(self.generic_value(table, name, ctype, i, allowed))
            rows.append(tuple(row))
        sql = f"INSERT INTO {table} ({', '.join(names)}) VALUES ({', '.join('?' for _ in names)})"
        self.conn.executemany(sql, rows)

    def generic_value(self, table, name, ctype, i, allowed):
        if name in allowed:
            return allowed[name][0]
        low = name.lower()
        t = "INT" if "INT" in ctype else "REAL" if ("REAL" in ctype or "FLOA" in ctype or "DOUB" in ctype) else "BLOB" if "BLOB" in ctype else "TEXT"
        if low.endswith("_at") or low in ("created_at", "updated_at"):
            return ID_TIME
        if low.endswith("_json"):
            return "[]" if "keyword" in low else "{}"
        if low in ("id",) or low.endswith("_id"):
            return f"{table[:1]}{i:08d}"
        if low in ("priority", "revision", "attempt_count", "sort_order", "position", "flag", "is_primary", "truncated_import", "photo_count", "index_seq", "import_order"):
            return 0
        if t == "INT":
            return 0
        if t == "REAL":
            return 0.0
        if t == "BLOB":
            return b""
        return f"{table[:1]}-{i}"

    # ---- 各表语义数据 ----
    def seed(self):
        rows = self.rows
        nsess = session_count(rows)
        sessions = [f"s{i:03d}" for i in range(nsess)]

        def sessions_overrides(i):
            return {"id": sessions[i], "name": f"Session {i}", "status": "photos_loaded",
                    "source_path": f"/photos/{sessions[i]}", "created_at": ID_TIME, "updated_at": ID_TIME,
                    "index_seq": i, "photo_count": rows // nsess}

        # 资产规划：前 40% 照片两两成对共享 asset_id，其余各自成资产；再留 10% 照片 asset_id NULL
        pairs = (rows * 2 // 5) // 2 * 2
        asset_of_photo = []
        for i in range(rows):
            if i >= rows - rows // 10:
                asset_of_photo.append(None)                      # 10% 无资产（走 UNION NULL 分支）
            elif i < pairs:
                asset_of_photo.append(f"a{i // 2:08d}")          # RAW/JPEG 对
            else:
                asset_of_photo.append(f"a{i:08d}")               # 单文件资产
        asset_ids = sorted({a for a in asset_of_photo if a})
        session_of_photo = [sessions[i % nsess] for i in range(rows)]

        def assets_overrides(i):
            return {"id": asset_ids[i], "status": "active", "created_at": ID_TIME, "updated_at": ID_TIME}

        def files_overrides(i):
            return {"id": f"f{i:08d}", "volume_id": "dev:1", "file_identity": str(i),
                    "normalized_path": f"/photos/{session_of_photo[i]}/IMG_{i:05d}.jpg",
                    "filename": f"IMG_{i:05d}.jpg", "extension": ".jpg", "media_type": "image",
                    "file_size": 2_000_000 + i, "file_mtime_ms": 1_700_000_000_000 + i,
                    "checksum": f"chk{i:06d}", "online_status": "online",
                    "last_seen_at": ID_TIME, "created_at": ID_TIME, "updated_at": ID_TIME}

        member_photo_indexes = [i for i, a in enumerate(asset_of_photo) if a]

        def members_overrides(j):
            i = member_photo_indexes[j]
            return {"asset_id": asset_of_photo[i], "file_id": f"f{i:08d}",
                    "member_role": "camera_jpeg", "is_primary": 1,
                    "binding_source": "backfill"}

        # 每个资产一条 session_assets（display_file_id = 资产的首个文件）
        first_file_of_asset = {}
        for i, aid in enumerate(asset_of_photo):
            if aid and aid not in first_file_of_asset:
                first_file_of_asset[aid] = f"f{i:08d}"
        sa = [(session_of_photo[asset_of_photo.index(aid)], aid) for aid in asset_ids]

        def session_assets_overrides(i):
            aid = sa[i][1]
            return {"session_id": sa[i][0], "asset_id": aid,
                    "display_file_id": first_file_of_asset.get(aid),
                    "import_order": i, "added_at": ID_TIME}

        def photos_overrides(i):
            archived = None if i % 20 else ID_TIME          # 5% 已移出（visible 过滤）
            checksum = f"chk{i:06d}"
            if i % 100 == 0 and i + 1 < rows:
                checksum = f"dup{i // 100:05d}"             # 精确重复组（每 100 张一组）
            elif i % 100 == 1 and i - 1 >= 0:
                checksum = f"dup{i // 100:05d}"
            return {"id": f"p{i:08d}", "session_id": session_of_photo[i],
                    "filepath": f"/photos/{session_of_photo[i]}/IMG_{i:05d}.jpg",
                    "filename": f"IMG_{i:05d}.jpg", "checksum": checksum,
                    "status": "ready", "width": 6000, "height": 4000,
                    "asset_id": asset_of_photo[i], "asset_file_id": f"f{i:08d}",
                    "archived_at": archived,
                    "created_at": ID_TIME, "updated_at": ID_TIME}

        def cache_overrides(i):
            return {"photo_id": f"p{i:08d}", "session_id": session_of_photo[i],
                    "rating": i % 6, "label": ["Red", "Green", "Blue", "None"][i % 4],
                    "date_taken": f"2026:01:{i % 28 + 1:02d} 10:00:00",
                    "camera_make": "Canon", "camera_model": ["R5", "R6"][i % 2],
                    "lens_model": "RF 24-70", "focal_length": 50.0, "f_number": 2.8,
                    "exposure_time": "1/500", "iso": 100 + i % 800,
                    "gps_latitude": 31.2, "gps_longitude": 121.4,
                    "width": 6000, "height": 4000, "file_size": 2_000_000 + i,
                    "file_mtime": ID_TIME, "keywords": "[]", "iptc_json": "{}",
                    "cached_at": ID_TIME, "updated_at": ID_TIME}

        def face_overrides(i):
            photo = i * 3
            return {"photo_id": f"p{photo:08d}", "session_id": session_of_photo[photo],
                    "bbox_x": 0.1, "bbox_y": 0.1, "bbox_w": 0.2, "bbox_h": 0.2,
                    "embedding": bytes([i % 251]) * 64, "confidence": 0.9,
                    "analysis_signature": "{}", "created_at": ID_TIME, "quality": 0.8,
                    "face_size_px": 120.0, "roll_degrees": 0.0,
                    "model_id": "face", "model_version": "1", "embedding_dim": 64}

        def hash_overrides(i):
            photo = i * 2
            return {"photo_id": f"p{photo:08d}", "session_id": session_of_photo[photo],
                    "hash_hex": f"{i:016x}", "created_at": ID_TIME}

        def decision_overrides(i):
            photo = i * 4
            return {"session_id": session_of_photo[photo], "photo_id": f"p{photo:08d}",
                    "group_id": "g", "decision": ["keep", "reject", "pending"][i % 3],
                    "rating": i % 6, "color_label": "None", "decision_source": "manual",
                    "revision": 1, "created_at": ID_TIME, "updated_at": ID_TIME}

        def history_overrides(i):
            return {"session_id": sessions[i % nsess], "operation_json": "[]",
                    "undone": 0, "created_at": ID_TIME}

        njobs = max(50, rows // 10)

        def job_overrides(i):
            status = "queued" if i % 5 == 0 else ("running" if i % 5 == 1 else "succeeded")
            return {"id": f"j{i:08d}", "type": "metadata.scan", "status": status,
                    "priority": i % 5, "updated_at": ID_TIME, "created_at": ID_TIME,
                    "lease_owner": "", "heartbeat_at": "", "started_at": "",
                    "finished_at": "", "error_code": "", "error_message": "",
                    "progress_current": 0, "progress_total": 0, "progress_message": "",
                    "cancel_requested_at": "", "dedupe_key": f"d{i:08d}",
                    "checkpoint_json": "{}", "scope_type": "session",
                    "scope_id": sessions[i % nsess], "attempt_count": 1}

        def triage_overrides(i):
            return {"photo_id": f"p{i:08d}", "session_id": session_of_photo[i],
                    "verdict": ["review", "keep", "reject"][i % 3],
                    "score": 0.5, "confidence": 0.5, "reasons_json": "[]",
                    "group_id": None, "policy_version": "v1", "input_fingerprint": "",
                    "computed_at": ID_TIME}

        ndeliveries = max(50, rows // 10)

        def delivery_overrides(i):
            return {"xmp_path": f"/photos/x/del_{i:05d}.xmp", "target_kind": "sidecar",
                    "status": ["synced", "writing", "pending", "conflict"][i % 4],
                    "revision": i, "base_fingerprint": f"fp{i:05d}",
                    "lease_owner": "", "heartbeat_at": "", "error_message": "",
                    "created_at": ID_TIME, "updated_at": ID_TIME,
                    "delivery_id": None}

        def item_overrides(i):
            return {"delivery_id": i // 2 + 1, "photo_id": f"p{(i * 7) % rows:08d}",
                    "module": "metadata", "status": "synced", "error_message": "",
                    "created_at": ID_TIME, "updated_at": ID_TIME}

        self.conn.execute("PRAGMA foreign_keys = OFF")
        self.insert("sessions", nsess, sessions_overrides)
        self.insert("assets", len(asset_ids), assets_overrides)
        self.insert("asset_files", rows, files_overrides)
        self.insert("asset_members", len(member_photo_indexes), members_overrides)
        self.insert("session_assets", len(sa), session_assets_overrides)
        self.insert("photos", rows, photos_overrides)
        self.insert("photo_metadata_cache", rows, cache_overrides)
        self.insert("face_observations", rows // 3, face_overrides)
        self.insert("similarity_hashes", rows // 2, hash_overrides)
        self.insert("culling_decisions", rows // 4, decision_overrides)
        self.insert("culling_history", max(50, rows // 20), history_overrides)
        self.insert("analysis_jobs", njobs, job_overrides)
        self.insert("triage_suggestions", rows, triage_overrides)
        self.insert("deliveries", ndeliveries, delivery_overrides)
        self.insert("delivery_items", ndeliveries * 2, item_overrides)
        self.conn.commit()
        self.conn.execute("PRAGMA foreign_keys = ON")
        for table in ("photos", "asset_files", "asset_members", "session_assets", "photo_metadata_cache",
                      "face_observations", "similarity_hashes", "culling_decisions", "analysis_jobs",
                      "triage_suggestions", "deliveries", "delivery_items"):
            n = self.conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            assert n > 0, f"seed produced no rows in {table}"


def hot_queries(rows: int, sessions: list[str], gids: list[str], deliveries: int):
    """返回 [(name, sql, params, alt_sql_or_None, note)]。"""
    nsess = session_count(rows)
    sid = sessions[0]
    photo_page_sql = (
        "SELECT p.id AS id, p.session_id AS session_id, p.filepath AS filepath, "
        "p.filename AS filename, p.checksum AS checksum, p.status AS status, "
        "p.created_at AS created_at, p.updated_at AS updated_at, "
        "(SELECT COUNT(*) FROM face_observations fo WHERE fo.photo_id = p.id "
        " AND fo.session_id = p.session_id) AS face_count "
        "FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id "
        "WHERE p.session_id = ? AND (1=1) AND p.archived_at IS NULL "
        "ORDER BY p.filename DESC LIMIT ?"
    )
    distinct_variant = photo_page_sql.replace("SELECT p.id AS id", "SELECT DISTINCT p.id AS id", 1)
    assert distinct_variant != photo_page_sql
    placeholders = ",".join("?" for _ in gids)
    asset_page_cte = (
        "WITH matching AS (SELECT p.rowid AS rowid, COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid "
        " FROM photos p LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id "
        " WHERE p.session_id = ? AND 1=1 AND p.archived_at IS NULL), "
        "asset_groups AS (SELECT gid, MIN(rowid) AS first_rowid FROM matching "
        " GROUP BY gid HAVING MIN(rowid) > ? ORDER BY MIN(rowid) LIMIT ?) "
        "SELECT gid, first_rowid FROM asset_groups ORDER BY first_rowid"
    )
    no_order_sql = photo_page_sql.split(" ORDER BY ")[0]
    distinct_no_order = distinct_variant.split(" ORDER BY ")[0]
    return [
        ("photo.list_page A (DISTINCT, before)", distinct_variant, (sid, 200), None,
         "改动前：SELECT DISTINCT + LEFT JOIN 1:1"),
        ("photo.list_page B (no DISTINCT, after)", photo_page_sql, (sid, 200), None,
         "改动后：无 DISTINCT（每张照片至多一行）"),
        ("photo.list_page A2 (DISTINCT, no ORDER BY)", distinct_no_order, (sid,), None,
         "隔离 DISTINCT 自身成本（去掉 ORDER BY temp b-tree 干扰）"),
        ("photo.list_page B2 (no DISTINCT, no ORDER BY)", no_order_sql, (sid,), None,
         "同一查询去掉 DISTINCT 后"),
        ("photo.asset_page CTE (cursor drill-down)", asset_page_cte, (sid, 0, 200), None,
         "资产分组游标兼容的 CTE"),
        ("photo.asset_page chunk IN (800/chunk)",
         "SELECT id, session_id, filepath, filename FROM photos p WHERE p.session_id = ? "
         f"AND COALESCE(NULLIF(asset_id, ''), id) IN ({placeholders}) AND p.archived_at IS NULL "
         "ORDER BY p.rowid", (sid,) + tuple(gids[:800]), None, "800 个 gid 的单块 IN"),
        ("job.queue_poll (analysis_jobs)",
         "SELECT id, type, status, priority, updated_at FROM analysis_jobs "
         "WHERE status = ? ORDER BY priority ASC, updated_at ASC, rowid ASC", ("queued",), None,
         "队列 claim 前的候选扫描"),
        ("triage.suggestions_load (whole session)",
         "SELECT photo_id, verdict, score, confidence, reasons_json, group_id, policy_version, "
         "input_fingerprint, computed_at FROM triage_suggestions WHERE session_id = ? "
         "ORDER BY photo_id", (sid,), None, "20k 会话口径：整会话候选"),
        ("delivery.getMany (xmp_path IN 100)",
         "SELECT id, xmp_path, status, revision, base_fingerprint FROM deliveries "
         f"WHERE xmp_path IN ({','.join('?' for _ in range(100))})",
         tuple(f"/photos/x/del_{i:05d}.xmp" for i in range(100)), None, "交付批量读"),
        ("metadata.cache_by_session",
         "SELECT photo_id, session_id, rating, label, keywords, iptc_json "
         "FROM photo_metadata_cache WHERE session_id = ?", (sid,), None, "元数据缓存批读"),
        ("fk.delivery_items_by_delivery (indexed)",
         "SELECT id, delivery_id, photo_id, module, status FROM delivery_items WHERE delivery_id = ?",
         (1,), None, "FK 子行点查，UNIQUE 自动索引"),
        ("fk.session_assets_display_file_id (no leading index)",
         "SELECT session_id, asset_id FROM session_assets WHERE display_file_id = ?",
         ("f00000000",), None, "唯一缺前导索引的 FK 子列 ⇒ SCAN"),
        ("photo.lookup_by_ids (800/chunk)",
         "SELECT id, session_id, filepath FROM photos WHERE id IN ("
         f"{','.join('?' for _ in range(800))})",
         tuple(f"p{i:08d}" for i in range(800)), None, "getLookupByIds 单块"),
    ]


def explain(conn: sqlite3.Connection, sql: str, params) -> list[str]:
    try:
        return [r[3] for r in conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()]
    except sqlite3.Error as exc:  # pragma: no cover - 只在 SQL 漂移时触发
        return [f"ERROR: {exc}"]


def time_query(conn: sqlite3.Connection, sql: str, params, repeats: int, warmup: int = 3) -> float:
    for _ in range(warmup):
        conn.execute(sql, params).fetchall()
    times = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        conn.execute(sql, params).fetchall()
        times.append((time.perf_counter() - t0) * 1000.0)
    return statistics.median(times)


def compare_distinct(conn, sql_old, params, sql_new, repeats) -> dict:
    old = time_query(conn, sql_old, params, repeats)
    new = time_query(conn, sql_new, params, repeats)
    return {"old_ms": old, "new_ms": new,
            "speedup": (old / new) if new else float("inf")}



def loop_prepare_bench(conn: sqlite3.Connection, repeats: int, iters: int = 1000) -> dict:
    """分块/逐行循环里「每轮重新 prepare」vs「复用已编译语句」的微基准（数量级估算）。

    做法：A 每轮给 SQL 追加**唯一注释**（绕过 CPython sqlite3 的语句缓存，强制重新
    sqlite3_prepare + 解析）；B 用同一 SQL 文本（等价于 DBStatement 复用）。
    差值 / 轮数 ≈ 一次 prepare 的成本量级（真实 Swift 侧是 sqlite3_prepare_v2，
    不含 Python wrapper 分配，故这里是上界估计）。
    """
    base_sql = "SELECT id FROM photos WHERE id = ?"
    params = ("p00000",)

    def run(vary_sql: bool) -> None:
        for i in range(iters):
            sql = base_sql + (f" /* {i} */" if vary_sql else "")
            conn.execute(sql, params).fetchall()

    def measure(vary: bool) -> float:
        for _ in range(3):
            run(vary)
        samples = []
        for _ in range(repeats):
            t0 = time.perf_counter()
            run(vary)
            samples.append((time.perf_counter() - t0) * 1000.0)
        return statistics.median(samples)

    prepare_each = measure(True)
    reuse = measure(False)
    return {
        "iters": iters,
        "prepare_each_ms": prepare_each,
        "reuse_ms": reuse,
        "speedup": (prepare_each / reuse) if reuse else float("inf"),
        "per_prepare_us": (prepare_each - reuse) * 1000.0 / iters,
    }

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Gather 热点 SQL 基准（真实 DDL + 合成数据；开发工具，不进 CI）")
    ap.add_argument("--rows", type=int, default=5000, help="合成照片数（默认 5000；20k/50k 用于放大）")
    ap.add_argument("--seed", type=int, default=42, help="数据随机种子（默认 42，确定性）")
    ap.add_argument("--repeats", type=int, default=15, help="每条查询计时次数（取中位数，默认 15）")
    ap.add_argument("--compare", action="store_true", help="额外跑 A/B（改动前 SQL 变体）并打印加速比")
    ap.add_argument("--json", action="store_true", help="输出 JSON（含原始 ms 与 plan）")
    ap.add_argument("--keep-db", metavar="PATH", help="保留合成库文件到指定路径（默认临时库用完即删）")
    args = ap.parse_args(argv)
    if args.rows < 100:
        raise SystemExit("perf-sqlite-bench: --rows 至少 100")

    ddl = extract_ddl()
    conn = sqlite3.connect(":memory:")
    conn.executescript(ddl)
    tables, indexes, fks = schema_facts(conn)
    if (tables, indexes, fks) != (EXPECTED_TABLES, EXPECTED_INDEXES, EXPECTED_FKS):
        raise SystemExit(
            f"perf-sqlite-bench: schema drift: tables={tables} indexes={indexes} fks={fks} "
            f"(expected {EXPECTED_TABLES}/{EXPECTED_INDEXES}/{EXPECTED_FKS})")
    t0 = time.perf_counter()
    Seeder(conn, args.rows, args.seed).seed()
    seed_ms = (time.perf_counter() - t0) * 1000.0

    sessions = [f"s{i:03d}" for i in range(session_count(args.rows))]
    gids = [f"a{i:08d}" for i in range(200)]
    deliveries = max(50, args.rows // 10)

    queries = hot_queries(args.rows, sessions, gids, deliveries)
    results = []
    for name, sql, params, alt, note in queries:
        plan = explain(conn, sql, params)
        ms = time_query(conn, sql, params, args.repeats)
        entry = {"name": name, "ms": round(ms, 3), "note": note, "plan": plan}
        if alt:
            entry["alt_ms"] = compare_distinct(conn, sql, params, alt, args.repeats)["old_ms"]
        results.append(entry)

    ab = None
    ab2 = None
    if args.compare:
        old_name, old_sql, old_params, _, _ = queries[0]
        new_name, new_sql, _, _, _ = queries[1]
        ab = compare_distinct(conn, old_sql, old_params, new_sql, args.repeats)
        ab["a"] = old_name
        ab["b"] = new_name
        a2_name, a2_sql, a2_params, _, _ = queries[2]
        b2_name, b2_sql, _, _, _ = queries[3]
        ab2 = compare_distinct(conn, a2_sql, a2_params, b2_sql, args.repeats)
        ab2["a"] = a2_name
        ab2["b"] = b2_name
    prepare_ab = loop_prepare_bench(conn, max(5, args.repeats // 2)) if args.compare else None

    if args.keep_db:
        disk = sqlite3.connect(args.keep_db)
        with disk:
            conn.backup(disk)
        disk.close()

    if args.json:
        print(json.dumps({"rows": args.rows, "seed": args.seed, "repeats": args.repeats,
                          "schema": {"tables": tables, "indexes": indexes, "fks": fks},
                          "seed_ms": round(seed_ms, 1), "queries": results,
                          "compare": ab, "compare_no_order": ab2,
                          "prepare_ab": prepare_ab},
                         ensure_ascii=False, indent=2))
        return 0

    print(f"perf-sqlite-bench: rows={args.rows} seed={args.seed} repeats={args.repeats} "
          f"db={'temp' if not args.keep_db else args.keep_db}")
    print(f"schema: tables={tables} indexes={indexes} fks={fks}（与 SchemaCurrent.expected* 一致）")
    print(f"seed: {seed_ms:.0f} ms（确定性合成数据）\n")
    print(f"{'query':<46}{'median ms':>11}  note")
    print("-" * 100)
    for entry in results:
        print(f"{entry['name']:<46}{entry['ms']:>11.3f}  {entry['note']}")
    print("\nEXPLAIN QUERY PLAN:")
    for entry in results:
        print(f"  [{entry['name']}]")
        for line in entry["plan"]:
            print(f"    {line}")
    for label, pair in (("A/B 带 ORDER BY", ab), ("A/B 无 ORDER BY（隔离 DISTINCT）", ab2)):
        if not pair:
            continue
        print(f"\n{label}（--compare）:")
        print(f"  A: {pair['a']}  {pair['old_ms']:.3f} ms")
        print(f"  B: {pair['b']}  {pair['new_ms']:.3f} ms")
        print(f"  加速比: {pair['speedup']:.2f}x")
    if prepare_ab:
        print("\nprepare hoist 微基准（--compare；单行 SELECT × %d，Python wrapper 近似）:" % prepare_ab["iters"])
        print(f"  A: 每轮重新 prepare（SQL 文本唯一） {prepare_ab['prepare_each_ms']:.2f} ms")
        print(f"  B: 复用已编译语句（同 SQL）      {prepare_ab['reuse_ms']:.2f} ms")
        print(f"  约 {prepare_ab['per_prepare_us']:.1f} µs / 次 prepare"
              f"（{prepare_ab['speedup']:.1f}x）—— 用于估算循环内 prepare 的数量级成本")
    if args.keep_db:
        print(f"\n合成库已保留: {args.keep_db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
