// Browser-facing logic, with every browser API injected so tests can drive it with fakes.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DeskTabSendController = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const MENU_SEND = 'desk-send';
  const MENU_BRING = 'desk-bring';

  // deps: { api (browser/chrome), core, fetchFn, WebSocketCtor, getSettings(), now(), setTimeoutFn, random() }
  function createController(deps) {
    const api = deps.api, core = deps.core;
    const backoff = new core.Backoff();
    const seen = new core.Seen(50);
    const pendingRestore = new Map(); // tabId -> tab to restore once it finishes loading
    let ws = null;
    let timer = null;
    let status = { connected: false, lastError: '' };

    function setBadge(text) {
      try { api.action.setBadgeText({ text }); } catch (e) { /* no badge support */ }
    }

    async function collect(tabId) {
      try {
        const s = await api.tabs.sendMessage(tabId, { type: 'desk-collect' });
        return s && typeof s === 'object' ? s : {};
      } catch (e) {
        return {}; // page has no content script (a store page, a not yet loaded tab): send the address alone
      }
    }

    async function post(req) {
      const res = await deps.fetchFn(req.url, req.init);
      if (!res || !res.ok) throw new Error('placer answered ' + (res ? res.status : 'nothing'));
    }

    // "Open this tab on the other Mac". Resolves true when the placer accepted it.
    async function sendTab(tabId) {
      const settings = core.normalizeSettings(await deps.getSettings());
      const tab = await api.tabs.get(tabId);
      const payload = core.buildPayload(tab, await collect(tabId), deps.now());
      if (!payload) { setBadge('x'); return false; }
      try {
        await post(core.buildSendRequest(settings, payload));
        setBadge('');
        return true;
      } catch (e) {
        status.lastError = String(e && e.message || e);
        setBadge('!');
        return false;
      }
    }

    async function sendActiveTab() {
      const tabs = await api.tabs.query({ active: true, lastFocusedWindow: true });
      if (!tabs || tabs.length === 0 || tabs[0].id === undefined) return false;
      return sendTab(tabs[0].id);
    }

    // "Bring this tab here".
    async function bring() {
      const settings = core.normalizeSettings(await deps.getSettings());
      try { await post(core.buildBringRequest(settings)); setBadge(''); return true; }
      catch (e) { status.lastError = String(e && e.message || e); setBadge('!'); return false; }
    }

    async function handleIncoming(raw) {
      const m = core.parseIncoming(raw);
      if (!m || !seen.check(m.id)) return false;
      if (m.kind === 'send-active-tab') return sendActiveTab();
      const created = await api.tabs.create({ url: m.tab.url, active: true });
      if (created && created.id !== undefined) pendingRestore.set(created.id, m.tab);
      return true;
    }

    function onTabUpdated(tabId, changeInfo) {
      if (changeInfo && changeInfo.status === 'complete' && pendingRestore.has(tabId)) {
        const tab = pendingRestore.get(tabId);
        pendingRestore.delete(tabId);
        // Best effort: if the page has no content script the tab simply stays at the top.
        Promise.resolve(api.tabs.sendMessage(tabId, { type: 'desk-restore', tab })).catch(function () {});
      }
    }

    function onTabRemoved(tabId) { pendingRestore.delete(tabId); }

    async function connect() {
      if (ws) return;
      const settings = core.normalizeSettings(await deps.getSettings());
      let sock;
      try { sock = new deps.WebSocketCtor(core.wsUrl(settings)); }
      catch (e) { scheduleReconnect(); return; }
      ws = sock;
      sock.onopen = function () {
        backoff.reset();
        status = { connected: true, lastError: '' };
        sock.send(core.buildHello(settings));
      };
      sock.onmessage = function (ev) { handleIncoming(ev.data).catch(function () {}); };
      const lost = function () {
        if (ws === sock) ws = null;
        status.connected = false;
        scheduleReconnect();
      };
      sock.onclose = lost;
      sock.onerror = function () { status.lastError = 'event socket error'; };
    }

    function scheduleReconnect() {
      if (timer !== null) return;
      const delay = backoff.next(deps.random ? deps.random() : 0);
      timer = deps.setTimeoutFn(function () { timer = null; connect(); }, delay);
    }

    function setupMenus(settings) {
      const s = core.normalizeSettings(settings);
      try {
        api.contextMenus.removeAll(function () {
          api.contextMenus.create({ id: MENU_SEND, title: 'Open this tab on ' + s.targetName, contexts: ['page', 'action'] });
          api.contextMenus.create({ id: MENU_BRING, title: 'Bring ' + s.targetName + "'s tab here", contexts: ['page', 'action'] });
        });
      } catch (e) { /* menus unavailable */ }
    }

    function onMenuClicked(info, tab) {
      if (info.menuItemId === MENU_SEND && tab && tab.id !== undefined) return sendTab(tab.id);
      if (info.menuItemId === MENU_BRING) return bring();
      return Promise.resolve(false);
    }

    function onActionClicked(tab) {
      return tab && tab.id !== undefined ? sendTab(tab.id) : Promise.resolve(false);
    }

    return {
      sendTab, sendActiveTab, bring, handleIncoming, onTabUpdated, onTabRemoved,
      connect, setupMenus, onMenuClicked, onActionClicked,
      get status() { return status; },
      get connected() { return ws !== null; },
    };
  }

  return { createController, MENU_SEND, MENU_BRING };
});
