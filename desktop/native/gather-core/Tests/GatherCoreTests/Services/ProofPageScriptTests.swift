// desktop/native/gather-core/Tests/GatherCoreTests/Services/ProofPageScriptTests.swift
// Wave4b / task-43：proof.js 的 **JS 级**回归（node 驱动真实脚本，不只是断言字符串）。
//
// 覆盖：share.json 404 的 http(s) fail-closed、file:// 本地回退、到期只读（下载禁用 +
// submit early return）、正常分享仍可下载、口令门未验证不可提交。
// 边界：用临时目录 + 系统 node（PATH 或常见安装路径）；不触网、不依赖浏览器。

import Foundation
import Testing
@testable import GatherApplication

@Suite("proof 页脚本（JS 级）")
struct ProofPageScriptTests {
    @Test("proof.js：fail-closed / 到期 / 正常 / 口令门行为（node 驱动）")
    func proofScriptBehaviors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-proof-js-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch {
                // 临时目录清理失败不影响断言。
            }
        }
        let proofPath = root.appendingPathComponent("proof.js")
        try GalleryBuilder.proofJS.write(to: proofPath, atomically: true, encoding: .utf8)
        let harnessPath = root.appendingPathComponent("proof-harness.js")
        try Self.harnessJS.write(to: harnessPath, atomically: true, encoding: .utf8)

        let node = Self.nodeCommand()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node.executable)
        process.arguments = node.prefix + [harnessPath.path, proofPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            Issue.record("无法启动 node（JS 级测试需要 node）：\(error)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0,
                "proof.js JS 级行为不符合预期：\(output)")
        for marker in [
            "OK fail-closed", "OK legacy-file-fallback", "OK expiry-locked",
            "OK unlocked-download", "OK password-gate",
        ] {
            #expect(output.contains(marker), "缺少场景断言：\(marker)（output=\(output)）")
        }
    }

    /// 优先按 PATH 查找 node（swift test 从 shell 启动时 PATH 通常含 nvm/homebrew），
    /// 再试常见安装路径，最后兜底 /usr/bin/env node。
    private static func nodeCommand() -> (executable: String, prefix: [String]) {
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                let candidate = String(directory) + "/node"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return (candidate, [])
                }
            }
        }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return (path, [])
        }
        return ("/usr/bin/env", ["node"])
    }

    /// 浏览器环境最小桩 + 场景断言（真实 proof.js 由 vm.runInContext 执行）。
    private static let harnessJS = #"""
const fs = require('fs');
const vm = require('vm');
const proofPath = process.argv[2];
const source = fs.readFileSync(proofPath, 'utf8');

function makeElement(id) {
  var el = {
    id: id,
    hidden: true,
    disabled: false,
    textContent: '',
    value: '',
    _click: null,
    addEventListener: function (event, handler) { if (event === 'click') { el._click = handler; } },
    focus: function () {},
    querySelector: function () { return null; },
    classList: { add: function () {}, remove: function () {} }
  };
  return el;
}

function runScenario(origin, fetchImpl) {
  return new Promise(function (resolve) {
    var ids = ['picked', 'locked-note', 'expiry-note', 'password-gate',
               'gate-password', 'gate-submit', 'gate-error', 'download',
               'select-all', 'clear-all'];
    var elements = {};
    ids.forEach(function (id) { elements[id] = makeElement(id); });
    elements['password-gate'].hidden = true;
    elements['download'].textContent = '下载选择（selection.json）';

    var bodyClasses = new Set(['proof', 'gate-pending']);
    var state = { blobCreated: false };
    var documentStub = {
      title: '客户校样',
      body: { classList: {
        add: function (name) { bodyClasses.add(name); },
        remove: function (name) { bodyClasses.delete(name); },
        toggle: function (name, on) {
          if (on) { bodyClasses.add(name); } else { bodyClasses.delete(name); }
        },
        contains: function (name) { return bodyClasses.has(name); }
      } },
      querySelectorAll: function (selector) {
        if (selector === '.cell') { return []; }
        if (selector === '.proof-actions button') { return [elements['download']]; }
        return [];
      },
      getElementById: function (id) { return elements[id] || null; },
      createElement: function () {
        return { href: '', download: '', click: function () { state.blobCreated = true; } };
      }
    };
    var windowStub = {
      location: { protocol: origin },
      localStorage: {
        getItem: function () { return null; },
        setItem: function () {}
      },
      fetch: fetchImpl,
      crypto: undefined,
      TextEncoder: (typeof TextEncoder === 'function' ? TextEncoder : undefined)
    };
    var sandbox = {
      window: windowStub,
      document: documentStub,
      localStorage: windowStub.localStorage,
      fetch: fetchImpl,
      Date: Date,
      Blob: function () {},
      URL: { createObjectURL: function () { return 'blob:test'; }, revokeObjectURL: function () {} },
      TextEncoder: windowStub.TextEncoder,
      crypto: undefined,
      console: console,
      setTimeout: setTimeout,
      clearTimeout: clearTimeout,
      Promise: Promise
    };
    vm.createContext(sandbox);
    vm.runInContext(source, sandbox, { filename: 'proof.js' });
    setTimeout(function () {
      if (elements.download._click) { elements.download._click(); }
      resolve({ bodyClasses: bodyClasses, elements: elements, state: state });
    }, 80);
  });
}

function expect(condition, message) {
  if (!condition) { throw new Error(message); }
}

async function main() {
  var lines = [];
  var r;

  // 1) http(s) 拿不到 share.json：fail-closed（页面锁定，不生成提交文件）
  r = await runScenario('https:', function () { return Promise.reject(new Error('missing')); });
  expect(r.bodyClasses.has('gate-pending'), 'fail-closed 应保持 gate-pending');
  expect(r.elements['download'].disabled === true, 'fail-closed 应禁用下载');
  expect(/无法读取分享配置/.test(r.elements['locked-note'].textContent),
         'fail-closed 应提示 share.json 缺失');
  expect(r.state.blobCreated === false, 'fail-closed 不得生成 selection.json');
  lines.push('OK fail-closed');

  // 2) file:// 本地预览：保留旧回退（可下载选择文件）
  r = await runScenario('file:', function () { return Promise.reject(new Error('missing')); });
  expect(r.bodyClasses.has('gate-pending') === false, 'file:// 本地预览应放行');
  expect(r.state.blobCreated === true, 'file:// 本地预览应能生成 selection.json');
  lines.push('OK legacy-file-fallback');

  // 3) 已到期：只读（禁用下载 + submit early return）
  var expiredShare = { version: 1, expiresAt: '2000-01-01T00:00:00Z' };
  r = await runScenario('https:', function () {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(expiredShare); } });
  });
  expect(r.bodyClasses.has('locked'), '到期应进入 locked 态');
  expect(r.elements['download'].disabled === true, '到期必须禁用下载');
  expect(/已过期/.test(r.elements['download'].textContent), '到期按钮文案应明示只读');
  expect(r.state.blobCreated === false, '到期后不得生成 selection.json');
  lines.push('OK expiry-locked');

  // 4) 正常分享：放开内容且下载可用（证明没有过度锁定）
  var normalShare = { version: 1, expiresAt: '2099-01-01T00:00:00Z' };
  r = await runScenario('https:', function () {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(normalShare); } });
  });
  expect(r.bodyClasses.has('gate-pending') === false, '正常分享应解锁内容');
  expect(r.elements['download'].disabled === false, '正常分享下载应可用');
  expect(r.state.blobCreated === true, '正常分享应能生成 selection.json');
  lines.push('OK unlocked-download');

  // 5) 口令门：gated 显示且未验证不能提交
  var gateShare = { version: 1, expiresAt: '2099-01-01T00:00:00Z',
                    passwordHash: 'deadbeef', passwordSalt: '00', passwordIterations: 1 };
  r = await runScenario('https:', function () {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(gateShare); } });
  });
  expect(r.bodyClasses.has('gated'), '口令分享应进入 gated 态');
  expect(r.elements['password-gate'].hidden === false, '口令输入应显示');
  expect(r.state.blobCreated === false, '未通过口令不得生成 selection.json');
  lines.push('OK password-gate');

  console.log(lines.join('\n'));
}

main().then(function () { process.exit(0); }).catch(function (error) {
  console.error(error.message);
  process.exit(1);
});
"""#
}
