// Browser-facing logic, with every browser API injected so tests can drive it with fakes.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DeskTabSendController = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const MENU_SEND = 'desk-send';
  const MENU_BRING = 'desk-bring';

  const ASK_TTL_MS = 60000;
  const RESTORE_KEY = 'pendingRestore';

  // deps: { api (browser/chrome), core, fetchFn, WebSocketCtor, subtle, cryptoObj, getSettings(), now(), setTimeoutFn, random() }
  function createController(deps) {
    const api = deps.api, core = deps.core;
    const backoff = new core.Backoff();
    const seen = new core.Seen(50);
    const memRestore = new Map(); // fallback when storage.session is missing
    let ws = null;
    let connecting = false;
    let timer = null;
    let session = null;       // { cnonce, snonce, authed, seq } for the current socket
    let ask = null;           // { id, at }: the other Mac asked for our tab; waits for a click
    let status = { connected: false, authenticated: false, lastError: '' };

    function setBadge(text) {
      try { api.action.setBadgeText({ text }); } catch (e) { /* no badge support */ }
    }

    function fail(msg) {
      status.lastError = msg;
      setBadge('!');
      return false;
    }

    // ---- tabs waiting for restore. Kept in storage.session so a stopped service worker does not forget them. ----
    const sessionStore = api.storage && api.storage.session;
    async function loadRestore() {
      if (!sessionStore) return Object.fromEntries(memRestore);
      try { const r = await sessionStore.get(RESTORE_KEY); return (r && r[RESTORE_KEY]) || {}; } catch (e) { return Object.fromEntries(memRestore); }
    }
    async function saveRestore(map) {
      if (!sessionStore) { memRestore.clear(); Object.keys(map).forEach(function (k) { memRestore.set(k, map[k]); }); return; }
      try { await sessionStore.set({ [RESTORE_KEY]: map }); } catch (e) { /* best effort */ }
    }

    // ---- permissions ----
    const ORIGINS = { origins: ['http://127.0.0.1/*'] };
    async function hasHostPermission() {
      if (!api.permissions || !api.permissions.contains) return true; // Chromium grants manifest host permissions at install
      try { return !!(await api.permissions.contains(ORIGINS)); } catch (e) { return false; }
    }
    // Firefox MV3 treats host_permissions as optional-until-granted. Must run inside a user gesture (click, menu).
    async function ensureHostPermission() {
      if (await hasHostPermission()) return true;
      try { return !!(await api.permissions.request(ORIGINS)); } catch (e) { return false; }
    }

    // ---- page state: the content script is injected on demand, only into a tab the person acted on ----
    async function inject(tabId) {
      if (!api.scripting || !api.scripting.executeScript) return;
      try { await api.scripting.executeScript({ target: { tabId }, files: ['src/core.js', 'src/content.js'] }); } catch (e) { /* no access to this page */ }
    }

    async function collect(tabId) {
      await inject(tabId);
      try {
        const s = await api.tabs.sendMessage(tabId, { type: 'desk-collect' });
        return s && typeof s === 'object' ? s : {};
      } catch (e) {
        return {}; // page cannot be read (a store page, a not yet loaded tab): send the address alone
      }
    }

    // ---- signed requests. Nothing is sent to the placer until it has proved it knows the token. ----
    async function post(settings, body) {
      if (!settings.token) throw new Error('set the shared token in options');
      if (!session || !session.authed) throw new Error('placer not verified');
      session.seq += 1;
      const sig = await deps.hmac(settings.token, core.httpProofInput(session.snonce, session.seq, body));
      const req = core.buildRequest(settings, body, { session: session.snonce, seq: session.seq, sig });
      const res = await deps.fetchFn(req.url, req.init);
      if (!res || !res.ok) throw new Error('placer answered ' + (res ? res.status : 'nothing'));
    }

    // "Open this tab on the other Mac". Resolves true when the placer accepted it. Call only from a person's action.
    async function sendTab(tabId) {
      const settings = core.normalizeSettings(await deps.getSettings());
      const tab = await api.tabs.get(tabId);
      const payload = core.buildPayload(tab, await collect(tabId), deps.now());
      if (!payload) { setBadge('x'); return false; }
      try {
        await post(settings, core.sendBody(payload));
        ask = null;
        setBadge('');
        return true;
      } catch (e) {
        return fail(String(e && e.message || e));
      }
    }

    async function activeTabId() {
      const tabs = await api.tabs.query({ active: true, lastFocusedWindow: true });
      return tabs && tabs.length > 0 && tabs[0].id !== undefined ? tabs[0].id : null;
    }

    // "Bring this tab here".
    async function bring() {
      const settings = core.normalizeSettings(await deps.getSettings());
      try { await post(settings, core.bringBody()); setBadge(''); return true; }
      catch (e) { return fail(String(e && e.message || e)); }
    }

    // A message from the placer over the authenticated socket.
    async function handleIncoming(raw) {
      const m = core.parseIncoming(raw);
      if (!m || !seen.check(m.id)) return false;
      if (m.kind === 'send-active-tab') {
        // The other Mac may ask, but the page address leaves only after a click here.
        ask = { id: m.id, at: deps.now() };
        setBadge('?');
        return false;
      }
      const created = await api.tabs.create({ url: m.tab.url, active: true });
      if (created && created.id !== undefined) {
        const map = await loadRestore();
        map[String(created.id)] = m.tab;
        await saveRestore(map);
      }
      return true;
    }

    function pendingAsk() { return !!ask && deps.now() - ask.at <= ASK_TTL_MS; }

    async function onTabUpdated(tabId, changeInfo) {
      if (!changeInfo || changeInfo.status !== 'complete') return;
      const map = await loadRestore();
      const key = String(tabId);
      if (!Object.prototype.hasOwnProperty.call(map, key)) return;
      const tab = map[key];
      delete map[key];
      await saveRestore(map);
      // Needs access to the page: without it the tab simply stays at the top.
      await inject(tabId);
      try { await api.tabs.sendMessage(tabId, { type: 'desk-restore', tab }); } catch (e) { /* best effort */ }
    }

    async function onTabRemoved(tabId) {
      const map = await loadRestore();
      if (Object.prototype.hasOwnProperty.call(map, String(tabId))) { delete map[String(tabId)]; await saveRestore(map); }
    }

    // ---- event socket ----
    async function connect() {
      if (ws || connecting) return;
      connecting = true; // set before the first await so two callers cannot both pass the check
      try {
        const settings = core.normalizeSettings(await deps.getSettings());
        if (!(await hasHostPermission())) { status.lastError = 'allow access to 127.0.0.1 in the extension permissions'; return; }
        if (!settings.token) { status.lastError = 'set the shared token in options'; return; }
        let sock;
        try { sock = new deps.WebSocketCtor(core.wsUrl(settings)); }
        catch (e) { scheduleReconnect(); return; }
        ws = sock;
        session = { cnonce: '', snonce: '', authed: false, seq: 0 };
        const mine = session;
        sock.onopen = function () {
          mine.cnonce = deps.nonce();
          status = { connected: true, authenticated: false, lastError: '' };
          sock.send(core.buildHello(mine.cnonce));
        };
        sock.onmessage = function (ev) { onSocketMessage(sock, mine, settings, ev.data).catch(function () {}); };
        const lost = function () {
          if (ws === sock) { ws = null; session = null; }
          status.connected = false;
          status.authenticated = false;
          scheduleReconnect();
        };
        sock.onclose = lost;
        sock.onerror = function () { status.lastError = 'event socket error'; };
      } finally {
        connecting = false;
      }
    }

    async function onSocketMessage(sock, mine, settings, raw) {
      if (ws !== sock) return;
      if (mine.authed) { await handleIncoming(raw); return; }
      const h = core.parseHandshake(raw);
      if (!h) return; // anything but the handshake is dropped until the placer has proved itself
      if (h.kind === 'challenge' && !mine.snonce) {
        const expect = await deps.hmac(settings.token, core.serverProofInput(mine.cnonce, h.snonce));
        if (!core.safeEqual(expect, h.proof)) {
          status.lastError = 'the program on this port does not know the shared token';
          setBadge('!');
          try { sock.close(); } catch (e) { /* already closed */ }
          return;
        }
        mine.snonce = h.snonce;
        sock.send(core.buildAuth(await deps.hmac(settings.token, core.clientProofInput(mine.cnonce, h.snonce))));
      } else if (h.kind === 'ready' && mine.snonce) {
        mine.authed = true;
        status.authenticated = true;
        status.lastError = '';
      }
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

    // Menu and toolbar clicks are the person's own action. They also answer a pending request from the other Mac.
    async function onMenuClicked(info, tab) {
      if (!(await ensureHostPermission())) return fail('access to 127.0.0.1 was not allowed');
      if (info.menuItemId === MENU_SEND && tab && tab.id !== undefined) { if (!ws) await connect(); return sendTab(tab.id); }
      if (info.menuItemId === MENU_BRING) return bring();
      return false;
    }

    async function onActionClicked(tab) {
      if (!(await ensureHostPermission())) return fail('access to 127.0.0.1 was not allowed');
      if (!ws) await connect();
      return tab && tab.id !== undefined ? sendTab(tab.id) : false;
    }

    return {
      sendTab, bring, handleIncoming, onTabUpdated, onTabRemoved,
      connect, setupMenus, onMenuClicked, onActionClicked, pendingAsk, ensureHostPermission,
      get status() { return status; },
      get connected() { return ws !== null; },
    };
  }

  return { createController, MENU_SEND, MENU_BRING };
});
