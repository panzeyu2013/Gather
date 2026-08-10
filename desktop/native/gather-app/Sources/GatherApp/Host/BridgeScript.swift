// desktop/native/gather-app/Sources/GatherApp/Host/BridgeScript.swift
// Phase 3.0 宿主与桥：WKUserScript 注入脚本（document start）。
// TS 源: desktop/src/preload/index.ts —— window.gather 全 20 方法同名 shim，
// 内部经 window.webkit.messageHandlers.gatherBridge 转发到 WebBridge，
// Promise 按 id 配对（等价 ipcRenderer.invoke 语义）。
//
// 渲染层（renderer/api/client.ts 与各 api 模块）零改动即可使用：
// - sendCommand 返回 { ok, data, error } 信封，client.ts 按原逻辑解包
// - onEvent 订阅返回退订函数（等价 preload 语义）
// - __gatherDispatchEvent 由 Swift 侧 evaluateJavaScript 调用（事件推送）
// - __gatherBridgeResolve 由 Swift 侧回传 WebResponse JSON
import Foundation

enum BridgeScript {
    static let source = """
    (function () {
      if (window.gather) return; // 防重复注入

      var pending = {};     // id -> {resolve, reject}
      var nextId = 1;
      var listeners = {};   // event -> Set<callback>
      var readyFired = false;

      function postMessage(payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gatherBridge) {
          window.webkit.messageHandlers.gatherBridge.postMessage(payload);
        }
      }

      // Swift 侧回传入口（WebBridge.respond）。
      // 完整信封 { id, ok, data, error } 传给渲染层 —— renderer/api/client.ts
      // 按 preload 语义解包（ok:false → CancelledError/Error）。
      window.__gatherBridgeResolve = function (response) {
        var entry = pending[response.id];
        if (!entry) return;
        delete pending[response.id];
        if (response.ok) entry.resolve(response);
        else {
          var err = new Error(response.error || 'Bridge error');
          err.type = String(response.error || '').indexOf('Cancelled') !== -1 ? 'CancelledError' : 'Error';
          err.params = undefined;
          entry.reject(err);
        }
      };

      // Swift 侧事件推送入口（WebBridge.dispatchEvent）
      window.__gatherDispatchEvent = function (event, data) {
        var set = listeners[event];
        if (!set) return;
        set.forEach(function (cb) {
          try { cb(data); } catch (e) { console.error('event handler error', e); }
        });
        if (event === 'engine:status' && data && data.status === 'ready' && !readyFired) {
          readyFired = true;
          var set2 = listeners['engine:status'];
          if (set2) set2.forEach(function (cb) { try { cb(data); } catch (e) {} });
        }
      };

      var gather = {
        sendCommand: function (command, params) {
          var id = 'w' + (nextId++);
          return new Promise(function (resolve, reject) {
            pending[id] = { resolve: resolve, reject: reject };
            postMessage({ id: id, command: command, params: params === undefined ? null : params });
          });
        },
        onEvent: function (event, callback) {
          if (!listeners[event]) listeners[event] = new Set();
          listeners[event].add(callback);
          return function () { listeners[event].delete(callback); };
        },
        onReady: function (callback) {
          var off = gather.onEvent('engine:status', function (data) {
            if (data && data.status === 'ready') { off(); callback(); }
          });
          return off;
        },
        onPluginImport: function (callback) {
          return gather.onEvent('c1:plugin-import', function (data) {
            callback(data && data.files ? data.files : []);
          });
        },
        getSelectedPhotos: function () {
          return gather.sendCommand('assets.candidates', {}).then(function (d) {
            return (d && d.photoIds) ? d.photoIds : [];
          });
        },
        reloadMetadata: function (sessionId) {
          return gather.sendCommand('metadata.orphans', sessionId ? { sessionId: sessionId } : {});
        },
        getC1Health: function () {
          return gather.sendCommand('assets.volumes', {}).then(function () {
            return { ok: false, c1Running: false, pluginInstalled: false, lastCheckedAt: null };
          });
        },
        getC1SyncState: function (sessionId) {
          return gather.sendCommand('culling.sync_status', { sessionId: sessionId }).then(function (d) { return d || {}; });
        },
        rendererReady: function () {
          return Promise.resolve();
        },
        selectDirectory: function (title) {
          return gather.sendCommand('assets.volumes', {}).then(function () { return null; });
        },
        selectFiles: function () { return Promise.resolve([]); },
        getVersion: function () {
          return Promise.resolve('native');
        },
        openDirectory: function (dirPath) {
          return Promise.resolve();
        },
        scanDirectory: function (dirPath) {
          return gather.sendCommand('index.scan', { sourcePath: dirPath });
        },
        createSessionFromDirectory: function (name, sourcePath) {
          return gather.sendCommand('session.create_from_directory', { name: name, sourcePath: sourcePath });
        },
        downloadDefaultModels: function () { return Promise.resolve(); },
        onModelDownloadProgress: function (callback) {
          return gather.onEvent('models:download-progress', callback);
        },
        modelsStatus: function () {
          return gather.sendCommand('face.models_status', {});
        },
        getAppLocale: function () {
          return Promise.resolve({ language: 'zh-CN' });
        },
        setLanguage: function (language) {
          return gather.sendCommand('settings.set_language', { language: language }).then(function () {
            return { language: language };
          });
        }
      };

      window.gather = gather;
    })();
    """
}
