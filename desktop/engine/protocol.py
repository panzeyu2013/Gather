# engine/protocol.py
# 长度前缀 MessagePack 协议 — 读写工具函数

from __future__ import annotations

import io
import logging
import os
import re
import struct
import sys
import threading
import traceback
import weakref
from typing import Any

import msgpack  # 不再静默降级；msgpack 是必须的运行时依赖

logger = logging.getLogger("gather.protocol")


_write_lock = threading.Lock()
_read_lock = threading.Lock()
_read_buffer = b""
MAX_MESSAGE_SIZE = 100 * 1024 * 1024
MAX_BUFFER_SIZE = 200 * 1024 * 1024
_stream_lock = threading.Lock()
_binary_stream_cache: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()

# Acceptable: sys.stdin / sys.stdout are long-lived process-global streams
# that will never be garbage-collected, so WeakKeyDictionary entries for
# them effectively live forever. This is fine — no leak, no premature eviction.


def _open_buffered_stream(stream: Any, mode: str) -> Any:
    try:
        return io.BufferedReader(io.FileIO(stream.fileno(), mode, closefd=False))
    except (OSError, io.UnsupportedOperation):
        return stream


def _get_binary_stream(stream):
    with _stream_lock:
        if stream in _binary_stream_cache:
            return _binary_stream_cache[stream]
        inferred_mode = "rb" if "r" in getattr(stream, "mode", "") else "wb"
        result = (
            stream.buffer
            if hasattr(stream, "buffer") and stream.buffer is not None
            else _open_buffered_stream(stream, inferred_mode)
        )
        _binary_stream_cache[stream] = result
        return result


def read_message(stream=sys.stdin) -> dict | None:
    """从 stream 读取一条长度前缀 MessagePack 消息。

    格式：[4 字节大端长度][MessagePack 负载]
    返回 None 表示 stream 已关闭。
    """
    global _read_buffer
    bin_stream = _get_binary_stream(stream)

    while True:
        # Step 1: Read more data from stream (I/O outside lock)
        chunk = bin_stream.read(65536)

        # Step 2: Process buffer under lock
        with _read_lock:
            if chunk:
                _read_buffer += chunk

            if len(_read_buffer) > MAX_BUFFER_SIZE:
                logger.error("Read buffer exceeded MAX_BUFFER_SIZE (%d), draining oversized data", MAX_BUFFER_SIZE)
                # Drain the buffer by dropping oversized frames; do not return
                # None (which signals stream EOF and kills the engine).
                _read_buffer = b""
                continue

            # Keep extracting messages while we have enough data
            while len(_read_buffer) >= 4:
                length = struct.unpack(">I", _read_buffer[:4])[0]
                total_needed = 4 + length

                if length > MAX_MESSAGE_SIZE:
                    logger.error("Message size %d exceeds MAX_MESSAGE_SIZE (%d)", length, MAX_MESSAGE_SIZE)
                    if len(_read_buffer) >= total_needed:
                        _read_buffer = _read_buffer[total_needed:]
                    else:
                        _read_buffer = b""
                        logger.error("Oversized message, clearing buffer")
                    continue

                if len(_read_buffer) < total_needed:
                    break

                payload = _read_buffer[4:total_needed]
                _read_buffer = _read_buffer[total_needed:]
                try:
                    return msgpack.unpackb(payload)  # type: ignore[no-any-return]
                except (ValueError, TypeError, msgpack.UnpackException, msgpack.ExtraData) as err:
                    logger.error("Failed to decode message: %s. Skipping corrupted frame.", err)
                    continue

            # If we read nothing and the buffer is exhausted, stream is closed
            if not chunk:
                if _read_buffer:
                    logger.error("Incomplete message remaining in buffer at stream EOF, discarding")
                    _read_buffer = b""
                return None


def write_message(msg: dict, stream=sys.stdout) -> None:
    """向 stream 写入一条长度前缀 MessagePack 消息。"""
    with _write_lock:
        bin_stream = _get_binary_stream(stream)
        payload = msgpack.packb(msg)
        bin_stream.write(struct.pack(">I", len(payload)))
        bin_stream.write(payload)
        bin_stream.flush()


def emit_event(event: str, data: dict | None = None) -> None:
    """发送事件消息到 stdout。"""
    write_message({"type": "event", "event": event, "data": data or {}})


def serialise_error(exc: Exception) -> dict[str, str]:
    """将异常序列化为可跨进程传输的 dict，包含 type + message + traceback。"""

    home = os.path.expanduser("~")
    tb_text = traceback.format_exc().replace(home, "~")
    for prefix in [home, "/Users/", "/Volumes/", "/private/", "/tmp/"]:
        # macOS-specific path redaction. Prefixes like /Users/, /Volumes/,
        # /private/, /tmp/ are common on macOS. For cross-platform support
        # this list should be derived from platform-specific temp/config dirs.
        tb_text = re.sub(rf'{re.escape(prefix)}[^\s"\']+', f'{prefix}***', tb_text)
    logger.error("Python error: %s: %s\n%s", type(exc).__name__, str(exc), tb_text)
    user_msg = str(exc).replace(home, "~")
    return {
        "type": type(exc).__name__,
        "message": user_msg[:500],
        "traceback": tb_text[:2000],
    }
