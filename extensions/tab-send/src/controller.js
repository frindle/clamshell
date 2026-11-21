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
  const HELD_TTL_MS = 600000;           // a held local-address tab waits ten minutes: walking to the other Mac takes a while
  const HELD_MAX = 5;
  const RESTORE_KEY = 'pendingRestore';
  const STATE_KEY = 'deskState';        // { seen: [ids], ask, held: [tabs] } kept across worker restarts
  const OPEN_LIMIT = 10;                // tabs the placer may open per minute without a click
  const OPEN_WINDOW_MS = 60000;
  const RESTORE_TTL_MS = 300000;
  const AUTH_WAIT_MS = 5000;

  // deps: { api (browser/chrome), core, fetchFn, WebSocketCtor, subtle, cryptoObj, getSettings(), now(), setTimeoutFn, random() }
  function createController(deps) {
    const api = deps.api, core = deps.core;
    const backoff = new core.Backoff();
    const seen = new core.Seen(50);
    const memRestore = new Map(); // fallback when storage.session is missing
    let ws = null;
    let connectPromise = null;
    let timer = null;
    let session = null;       // { cnonce, snonce, authed, seq } for the current socket
    let ask = null;           // { id, at }: the other Mac asked for our tab; waits for a click
    let held = [];            // [{ tab, at }]: tabs for local or private addresses; each opens only after a click
    let statePromise = null;
    let opens = [];           // times of tabs opened without a click, for the rate limit
    let authWaiters = [];
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

    // ---- small state that must survive the worker being stopped: seen ids, the pending question, a held local tab ----
    // One shared load: every caller awaits the same read, and what it finds is merged under anything already set.
    function loadState() {
      if (!statePromise) statePromise = readState();
      return statePromise;
    }
    async function readState() {
      if (!sessionStore) return;
      try {
        const r = await sessionStore.get(STATE_KEY);
        const s = r && r[STATE_KEY];
        if (s && typeof s === 'object') {
          if (Array.isArray(s.seen)) s.seen.forEach(function (id) { if (typeof id === 'string') seen.check(id); });
          if (!ask && s.ask && typeof s.ask.id === 'string') ask = { id: s.ask.id, at: Number(s.ask.at) || 0 };
          const stored = Array.isArray(s.held) ? s.held : (s.pendingOpen ? [s.pendingOpen] : []);
          const have = held.map(function (h) { return h.tab.url + '\n' + h.at; });
          stored.forEach(function (h) {
            if (h && h.tab && core.isSendableUrl(h.tab.url) && have.indexOf(h.tab.url + '\n' + (Number(h.at) || 0)) === -1) held.push({ tab: h.tab, at: Number(h.at) || 0 });
          });
          held = held.slice(-HELD_MAX);
        }
      } catch (e) { /* start empty */ }
    }
    async function saveState() {
      if (!sessionStore) return;
      try { await sessionStore.set({ [STATE_KEY]: { seen: seen.ids.slice(), ask, held } }); } catch (e) { /* best effort */ }
    }

    // ---- permissions ----
    const ORIGINS = { origins: ['http://127.0.0.1/*'] };
    async function hasHostPermission() {
      if (!api.permissions || !api.permissions.contains) return true; // Chromium grants manifest host permissions at install
      try { return !!(await api.permissions.contains(ORIGINS)); } catch (e) { return false; }
    }
    // Firefox MV3 treats host_permissions as optional-until-granted. Must run inside a user gesture (click, menu).
    // The request is the FIRST call in the handler (no await before it): Firefox drops the click context after an
    // await. Asking for something already granted resolves true without a prompt.
    function ensureHostPermission() {
      if (!api.permissions || !api.permissions.request) return Promise.resolve(true);
      try { return Promise.resolve(api.permissions.request(ORIGINS)).then(function (ok) { return !!ok; }, function () { return false; }); }
      catch (e) { return Promise.resolve(false); }
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
    // Resolves true once the placer has proved itself on the current socket; false if the socket is lost or time runs out.
    function waitAuthed() {
      if (session && session.authed) return Promise.resolve(true);
      if (!ws) return Promise.resolve(false);
      return new Promise(function (resolve) {
        let done = false;
        const finish = function (v) { if (!done) { done = true; resolve(v); } };
        authWaiters.push(finish);
        deps.setTimeoutFn(function () { finish(!!(session && session.authed)); }, AUTH_WAIT_MS);
      });
    }
    function releaseWaiters(v) { const w = authWaiters; authWaiters = []; w.forEach(function (f) { f(v); }); }

    function sessionKey(settings) { return core.wsUrl(settings) + '\n' + settings.token; }
    function dropSocket() {
      const old = ws;
      ws = null; session = null;
      releaseWaiters(false);
      status.connected = false; status.authenticated = false;
      if (old) { try { old.close(); } catch (e) { /* already closed */ } }
    }

    async function post(settings, body) {
      if (!settings.token) throw new Error('set the shared token in options');
      if (!core.tokenIsStrong(settings.token)) throw new Error('the shared token is too short: generate one in options');
      // The session proved the placer at one port with one token. If either changed since, it proves nothing about
      // what listens now: drop it and verify again before anything is sent.
      if (ws && session && session.key !== sessionKey(settings)) { dropSocket(); await connect(); }
      await waitAuthed();
      const sess = session; // captured: the socket may be lost across the awaits below
      if (!sess || !sess.authed || sess.key !== sessionKey(settings)) throw new Error('placer not verified');
      sess.seq += 1;
      const seq = sess.seq;
      const sig = await deps.hmac(settings.token, core.httpProofInput(sess.snonce, seq, body));
      const req = core.buildRequest(settings, body, { session: sess.snonce, seq, sig });
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
      await loadState();
      const m = core.parseIncoming(raw);
      if (!m || !seen.check(m.id)) return false;
      if (m.kind === 'send-active-tab') {
        // The other Mac may ask, but the page address leaves only after a click here.
        ask = { id: m.id, at: deps.now() };
        setBadge('?');
        await saveState();
        return false;
      }
      // An address on this machine or a private network is never opened unprompted: router pages, admin consoles
      // and dev servers are what a hostile placer would aim at. It waits for a click on the toolbar button.
      if (core.isLocalHost(m.tab.url)) {
        held.push({ tab: m.tab, at: deps.now() });
        held = held.slice(-HELD_MAX);
        setBadge('o');
        await saveState();
        return false;
      }
      const now = deps.now();
      opens = opens.filter(function (t) { return now - t < OPEN_WINDOW_MS; });
      if (opens.length >= OPEN_LIMIT) { fail('too many tabs from the placer in one minute; dropped'); await saveState(); return false; }
      opens.push(now);
      await saveState();
      return openTab(m.tab);
    }

    async function openTab(tab) {
      const created = await api.tabs.create({ url: tab.url, active: true });
      if (created && created.id !== undefined) {
        const map = await loadRestore();
        map[String(created.id)] = { tab, at: deps.now() };
        await saveRestore(map);
      }
      return true;
    }

    // A click while local-address tabs are held: open the oldest one still fresh (the click is the consent) instead of
    // sending. Returns 'opened', 'expired' (tabs were held but all had expired: the click is used up telling the
    // person so, and sends nothing) or 'none' (nothing was held).
    async function openHeld() {
      await loadState();
      if (held.length === 0) return 'none';
      const now = deps.now();
      const fresh = held.filter(function (h) { return now - h.at <= HELD_TTL_MS; });
      const hadExpired = fresh.length !== held.length;
      if (fresh.length === 0) {
        held = [];
        status.lastError = 'the held tab expired; ask for it again';
        setBadge('');
        await saveState();
        return 'expired';
      }
      const next = fresh[0];
      held = fresh.slice(1);
      setBadge(held.length > 0 ? 'o' : (hadExpired ? '' : ''));
      await saveState();
      await openTab(next.tab);
      return 'opened';
    }
    async function openPending() { return (await openHeld()) === 'opened'; }

    async function restoreState() { await loadState(); }
    function pendingAsk() { return !!ask && deps.now() - ask.at <= ASK_TTL_MS; }

    // Restores scroll and media once the tab reaches the page that was sent, not on the first finished load:
    // a redirect or sign-in page on another site would otherwise receive (and consume) the state.
    function sameOrigin(a, b) {
      try { return new URL(a).origin === new URL(b).origin; } catch (e) { return false; }
    }
    async function onTabUpdated(tabId, changeInfo, tabInfo) {
      if (!changeInfo || changeInfo.status !== 'complete') return;
      const map = await loadRestore();
      const key = String(tabId);
      if (!Object.prototype.hasOwnProperty.call(map, key)) return;
      const entry = map[key];
      const tab = entry && entry.tab ? entry.tab : entry;
      const at = entry && typeof entry.at === 'number' ? entry.at : null;
      if (at !== null && deps.now() - at > RESTORE_TTL_MS) { delete map[key]; await saveRestore(map); return; }
      if (tabInfo && typeof tabInfo.url === 'string' && !sameOrigin(tabInfo.url, tab.url)) return; // wait for the real page
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
    // A second caller gets the same in-flight attempt, so it returns when the socket exists (or the attempt failed).
    function connect() {
      if (ws) return Promise.resolve();
      if (!connectPromise) connectPromise = doConnect().finally(function () { connectPromise = null; });
      return connectPromise;
    }
    async function doConnect() {
      try {
        const settings = core.normalizeSettings(await deps.getSettings());
        if (!(await hasHostPermission())) { status.lastError = 'allow access to 127.0.0.1 in the extension permissions'; return; }
        if (!settings.token) { status.lastError = 'set the shared token in options'; return; }
        if (!core.tokenIsStrong(settings.token)) { status.lastError = 'the shared token is too short: generate one in options'; return; }
        let sock;
        try { sock = new deps.WebSocketCtor(core.wsUrl(settings)); }
        catch (e) { scheduleReconnect(); return; }
        ws = sock;
        session = { cnonce: '', snonce: '', authed: false, seq: 0, key: sessionKey(settings) };
        const mine = session;
        sock.onopen = function () {
          mine.cnonce = deps.nonce();
          status = { connected: true, authenticated: false, lastError: '' };
          // Client-first: prove knowledge of the token before the placer says anything keyed.
          deps.hmac(settings.token, core.helloProofInput(mine.cnonce)).then(function (proof) {
            if (ws === sock) sock.send(core.buildHello(mine.cnonce, proof));
          }).catch(function () {});
        };
        sock.onmessage = function (ev) { onSocketMessage(sock, mine, settings, ev.data).catch(function () {}); };
        const lost = function () {
          if (ws === sock) {
            ws = null; session = null; releaseWaiters(false);
            status.connected = false;
            status.authenticated = false;
            scheduleReconnect();
          } else if (ws === null) {
            scheduleReconnect(); // dropped on purpose (failed proof): retry later
          } // else a newer socket replaced this one: its state is not ours to touch
        };
        sock.onclose = lost;
        sock.onerror = function () { status.lastError = 'event socket error'; };
      } catch (e) { /* the next attempt retries */ }
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
          if (ws === sock) { ws = null; session = null; }
          releaseWaiters(false);
          try { sock.close(); } catch (e) { /* already closed */ }
          return;
        }
        mine.snonce = h.snonce;
        sock.send(core.buildAuth(await deps.hmac(settings.token, core.clientProofInput(mine.cnonce, h.snonce))));
      } else if (h.kind === 'ready' && mine.snonce) {
        mine.authed = true;
        backoff.reset(); // a good connect starts the delays over
        status.authenticated = true;
        status.lastError = '';
        releaseWaiters(true);
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
    function onMenuClicked(info, tab) {
      const granted = ensureHostPermission(); // first call, before any await
      return (async function () {
        if (!(await granted)) return fail('access to 127.0.0.1 was not allowed');
        if (info.menuItemId === MENU_SEND && tab && tab.id !== undefined) { if (!ws) await connect(); return sendTab(tab.id); }
        if (info.menuItemId === MENU_BRING) { if (!ws) await connect(); return bring(); }
        return false;
      })();
    }

    function onActionClicked(tab) {
      const granted = ensureHostPermission(); // first call, before any await
      return (async function () {
        if (!(await granted)) return fail('access to 127.0.0.1 was not allowed');
        const h = await openHeld();
        if (h === 'opened') return true;
        if (h === 'expired') return false; // never turn "open the held tab" into "send this tab"
        if (!ws) await connect();
        return tab && tab.id !== undefined ? sendTab(tab.id) : false;
      })();
    }

    return {
      sendTab, bring, handleIncoming, openPending, restoreState, onTabUpdated, onTabRemoved,
      connect, setupMenus, onMenuClicked, onActionClicked, pendingAsk, ensureHostPermission,
      get status() { return status; },
      get connected() { return ws !== null; },
    };
  }

  return { createController, MENU_SEND, MENU_BRING };
});
