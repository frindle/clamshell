// Wires the controller to the real browser. Works as a Chromium service worker and as a Firefox background script.
(function () {
  'use strict';
  if (typeof importScripts === 'function') importScripts('core.js', 'controller.js');
  const ext = typeof browser !== 'undefined' ? browser : chrome;
  const core = globalThis.DeskTabSend;
  const ctl = globalThis.DeskTabSendController.createController({
    api: ext,
    core,
    fetchFn: function (u, i) { return fetch(u, i); },
    WebSocketCtor: WebSocket,
    hmac: function (token, msg) { return core.hmacHex(crypto.subtle, token, msg); },
    nonce: function () { return core.randomNonce(crypto); },
    getSettings: function () { return ext.storage.local.get(['port', 'token', 'targetName']); },
    now: function () { return Date.now(); },
    setTimeoutFn: function (fn, ms) { return setTimeout(fn, ms); },
    random: Math.random,
  });

  // Toolbar click: also answers a request from the other Mac (badge "?"). Nothing leaves the browser without it.
ext.action.onClicked.addListener(function (tab) { ctl.onActionClicked(tab); });
  ext.contextMenus.onClicked.addListener(function (info, tab) { ctl.onMenuClicked(info, tab); });
  ext.tabs.onUpdated.addListener(function (id, change) { ctl.onTabUpdated(id, change); });
  ext.tabs.onRemoved.addListener(function (id) { ctl.onTabRemoved(id); });
  ext.runtime.onInstalled.addListener(function () { ext.storage.local.get(['port', 'token', 'targetName']).then(ctl.setupMenus); });
  ext.storage.onChanged.addListener(function () { ext.storage.local.get(['port', 'token', 'targetName']).then(ctl.setupMenus); });
  // A service worker can be stopped; the alarm brings the event socket back.
  ext.alarms.create('desk-keepalive', { periodInMinutes: 1 });
  ext.alarms.onAlarm.addListener(function () { ctl.connect(); });
  ctl.connect();
})();
