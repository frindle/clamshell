const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../src/core.js');
const { createController } = require('../src/controller.js');

const { webcrypto } = require('node:crypto');
const TOKEN = 'k'.repeat(40);
const settle = () => new Promise((r) => setTimeout(r, 40)); // webcrypto answers on another thread
const hmac = (token, m) => core.hmacHex(webcrypto.subtle, token, m);

// A fake placer. `serverToken` is what the program on the port knows; the real placer knows TOKEN.
function setup(over) {
  const o = over || {};
  const calls = { fetch: [], created: [], sent: [], badge: [], timers: [], injected: [], closed: 0, perms: [] };
  const tabs = { 7: { id: 7, url: 'https://a.test/p', title: 'P' } };
  const sess = {};
  const api = {
    tabs: {
      get: async (id) => tabs[id],
      query: async () => [tabs[7]],
      create: async (x) => { calls.created.push(x); return { id: 99 }; },
      sendMessage: async (id, msg) => { calls.sent.push([id, msg.type]); if (o.noContent) throw new Error('no receiver'); return msg.type === 'desk-collect' ? { scrollX: 0, scrollY: 40, media: null } : undefined; },
    },
    scripting: { executeScript: async (x) => { calls.injected.push(x.target.tabId); } },
    storage: o.noSession ? {} : { session: { get: async (k) => ({ [k]: sess[k] }), set: async (v) => Object.assign(sess, v) } },
    permissions: { contains: async () => !o.noPerm, request: async (p) => { calls.perms.push(p); return !o.denyPerm; } },
    action: { setBadgeText: (b) => calls.badge.push(b.text) },
    contextMenus: { removeAll: (cb) => cb(), create: (x) => (calls.menus = (calls.menus || []).concat(x.id)) },
  };
  class FakeWS {
    constructor(u) { this.url = u; this.sentMsgs = []; FakeWS.last = this; FakeWS.count = (FakeWS.count || 0) + 1; }
    send(m) { this.sentMsgs.push(JSON.parse(m)); }
    close() { calls.closed += 1; }
  }
  let n = 0;
  const ctl = createController({
    api, core,
    fetchFn: async (u, i) => { calls.fetch.push([u, JSON.parse(i.body), i.headers]); return { ok: !o.fail, status: o.fail ? 500 : 200 }; },
    WebSocketCtor: FakeWS,
    hmac,
    nonce: () => String(++n).padStart(32, '0'),
    getSettings: async () => ({ port: 6000, token: o.token === undefined ? TOKEN : o.token }),
    now: () => 1000,
    setTimeoutFn: (fn, ms) => { calls.timers.push(ms); return calls.timers.length; },
    random: () => 0,
  });
  return { ctl, calls, FakeWS, sess };
}

// Plays the placer's side of the handshake on the socket the controller opened.
async function handshake(ctl, FakeWS, serverToken) {
  await ctl.connect();
  const ws = FakeWS.last;
  ws.onopen();
  await settle();
  const cnonce = ws.sentMsgs[0].cnonce;
  const snonce = 'ee'.repeat(16);
  const proof = await hmac(serverToken === undefined ? TOKEN : serverToken, core.serverProofInput(cnonce, snonce));
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'challenge', snonce, proof }) });
  await settle();
  return { ws, cnonce, snonce };
}
async function login(ctl, FakeWS) {
  const h = await handshake(ctl, FakeWS);
  h.ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'ready' }) });
  await settle();
  return h;
}

test('send tab posts a signed request, never the token', async () => {
  const { ctl, calls, FakeWS } = setup();
  const { snonce } = await login(ctl, FakeWS);
  assert.equal(await ctl.sendTab(7), true);
  const [url, body, headers] = calls.fetch[0];
  assert.equal(url, 'http://127.0.0.1:6000/v1/tab-send');
  assert.equal(body.tab.scrollY, 40);
  assert.equal(body.tab.sentAt, 1000);
  assert.deepEqual(calls.injected, [7], 'content script injected on demand');
  assert.equal(headers['X-Desk-Session'], snonce);
  assert.equal(headers['X-Desk-Sig'], await hmac(TOKEN, core.httpProofInput(snonce, 1, JSON.stringify(body))));
  assert.ok(!JSON.stringify(calls.fetch).includes(TOKEN));
});

test('signatures use a rising sequence number', async () => {
  const { ctl, calls, FakeWS } = setup();
  await login(ctl, FakeWS);
  await ctl.sendTab(7); await ctl.bring();
  assert.deepEqual(calls.fetch.map((f) => f[2]['X-Desk-Seq']), ['1', '2']);
});

test('a page without the content script still sends its address', async () => {
  const { ctl, calls, FakeWS } = setup({ noContent: true });
  await login(ctl, FakeWS);
  assert.equal(await ctl.sendTab(7), true);
  assert.equal(calls.fetch[0][1].tab.scrollY, 0);
});

test('placer failure sets the error badge and reports false', async () => {
  const { ctl, calls, FakeWS } = setup({ fail: true });
  await login(ctl, FakeWS);
  assert.equal(await ctl.sendTab(7), false);
  assert.deepEqual(calls.badge, ['!']);
  assert.match(ctl.status.lastError, /500/);
});

test('a fake placer that does not know the token is rejected and gets nothing', async () => {
  const { ctl, calls, FakeWS } = setup();
  const { ws } = await handshake(ctl, FakeWS, 'wrong-token');
  assert.equal(calls.closed, 1);
  assert.match(ctl.status.lastError, /does not know the shared token/);
  assert.equal(ws.sentMsgs.length, 1, 'only the hello went out; no auth proof for an unverified server');
  assert.ok(!JSON.stringify(ws.sentMsgs).includes(TOKEN));
  // It cannot push a tab or a request, and a send refuses to talk to it.
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'open-tab', id: 'x', tab: { url: 'https://evil.test/' } }) });
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'ready' }) });
  await settle();
  assert.equal(calls.created.length, 0);
  assert.equal(await ctl.sendTab(7), false);
  assert.equal(calls.fetch.length, 0, 'no tab address reaches an unverified server');
  assert.match(ctl.status.lastError, /not verified/);
});

test('a server that skips the challenge cannot inject tabs', async () => {
  const { ctl, calls, FakeWS } = setup();
  await ctl.connect();
  FakeWS.last.onopen();
  FakeWS.last.onmessage({ data: JSON.stringify({ v: 1, kind: 'open-tab', id: 'x', tab: { url: 'https://evil.test/' } }) });
  await settle();
  assert.equal(calls.created.length, 0);
});

test('the client proof is sent only after the server proved itself, and it checks out', async () => {
  const { ctl, FakeWS } = setup();
  const { ws, cnonce, snonce } = await handshake(ctl, FakeWS);
  assert.equal(ws.sentMsgs[1].kind, 'auth');
  assert.equal(ws.sentMsgs[1].proof, await hmac(TOKEN, core.clientProofInput(cnonce, snonce)));
  assert.equal(ctl.status.authenticated, false, 'not authenticated until ready');
});

test('send-active-tab from the placer only raises a prompt; the address leaves on a click', async () => {
  const { ctl, calls, FakeWS } = setup();
  const { ws } = await login(ctl, FakeWS);
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'send-active-tab', id: 'r1' }) });
  await settle();
  assert.equal(calls.fetch.length, 0, 'nothing sent without a person');
  assert.equal(calls.badge.at(-1), '?');
  assert.equal(ctl.pendingAsk(), true);
  assert.equal(await ctl.onActionClicked({ id: 7 }), true);
  assert.equal(calls.fetch.length, 1);
  assert.equal(ctl.pendingAsk(), false);
});

test('open-tab creates a tab once, restores after load (state kept in storage.session), ignores a repeat', async () => {
  const { ctl, calls, FakeWS, sess } = setup();
  const { ws } = await login(ctl, FakeWS);
  const msg = JSON.stringify({ v: 1, kind: 'open-tab', id: 'm1', tab: { url: 'https://a.test/x', scrollY: 300 } });
  ws.onmessage({ data: msg });
  await settle();
  ws.onmessage({ data: msg });
  await settle();
  assert.deepEqual(calls.created, [{ url: 'https://a.test/x', active: true }]);
  assert.ok(sess.pendingRestore['99'], 'pending restore survives a worker restart');
  await ctl.onTabUpdated(99, { status: 'loading' });
  assert.equal(calls.sent.length, 0);
  await ctl.onTabUpdated(99, { status: 'complete' });
  await ctl.onTabUpdated(99, { status: 'complete' });
  assert.deepEqual(calls.sent, [[99, 'desk-restore']]);
  assert.deepEqual(sess.pendingRestore, {});
});

test('pending restore works from a fresh controller (worker restarted) and without storage.session', async () => {
  const a = setup();
  const { ws } = await login(a.ctl, a.FakeWS);
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'open-tab', id: 'm1', tab: { url: 'https://a.test/x', scrollY: 9 } }) });
  await settle();
  const { createController: mk } = require('../src/controller.js');
  const calls = [];
  const again = mk({ api: { storage: { session: { get: async (k) => ({ [k]: a.sess[k] }), set: async (v) => Object.assign(a.sess, v) } },
    scripting: { executeScript: async () => {} }, tabs: { sendMessage: async (id, m) => calls.push([id, m.type]) } },
    core, fetchFn: async () => ({ ok: true }), WebSocketCtor: a.FakeWS, hmac, nonce: () => 'x', getSettings: async () => ({}), now: () => 1, setTimeoutFn: () => 1 });
  await again.onTabUpdated(99, { status: 'complete' });
  assert.deepEqual(calls, [[99, 'desk-restore']]);
  const b = setup({ noSession: true });
  const lg = await login(b.ctl, b.FakeWS);
  lg.ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'open-tab', id: 'm2', tab: { url: 'https://a.test/y' } }) });
  await settle();
  await b.ctl.onTabUpdated(99, { status: 'complete' });
  assert.deepEqual(b.calls.sent, [[99, 'desk-restore']]);
});

test('hostile open-tab is dropped', async () => {
  const { ctl, calls } = setup();
  assert.equal(await ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'z', tab: { url: 'javascript:alert(1)' } })), false);
  assert.equal(calls.created.length, 0);
});

test('socket says hello with a nonce, reconnects with backoff after close', async () => {
  const { ctl, calls, FakeWS } = setup();
  await ctl.connect();
  const ws1 = FakeWS.last;
  assert.equal(ws1.url, 'ws://127.0.0.1:6000/v1/tab-events');
  ws1.onopen();
  await settle();
  assert.equal(ws1.sentMsgs[0].kind, 'hello');
  assert.match(ws1.sentMsgs[0].cnonce, /^[0-9a-f]{32}$/);
  assert.equal(ws1.sentMsgs[0].token, undefined);
  ws1.onclose();
  ws1.onclose();
  assert.deepEqual(calls.timers, [1000]); // one timer even if close fires twice
});

test('two connect() calls at once open one socket', async () => {
  const { ctl, FakeWS } = setup();
  FakeWS.count = 0;
  await Promise.all([ctl.connect(), ctl.connect(), ctl.connect()]);
  assert.equal(FakeWS.count, 1);
});

test('connect needs the host permission and a token', async () => {
  const a = setup({ noPerm: true });
  a.FakeWS.count = 0;
  await a.ctl.connect();
  assert.equal(a.FakeWS.count, 0);
  assert.match(a.ctl.status.lastError, /127\.0\.0\.1/);
  const b = setup({ token: '' });
  b.FakeWS.count = 0;
  await b.ctl.connect();
  assert.equal(b.FakeWS.count, 0);
  assert.match(b.ctl.status.lastError, /token/);
  // After a failed attempt a later one still works (the flag is released).
  const c = setup();
  c.FakeWS.count = 0;
  await c.ctl.connect();
  assert.equal(c.FakeWS.count, 1);
});

test('a click asks for the 127.0.0.1 permission when it is missing, and stops if refused', async () => {
  const a = setup({ noPerm: true, denyPerm: true });
  assert.equal(await a.ctl.onActionClicked({ id: 7 }), false);
  assert.deepEqual(a.calls.perms, [{ origins: ['http://127.0.0.1/*'] }]);
  assert.equal(a.calls.fetch.length, 0);
  const b = setup({ noPerm: true });
  await b.ctl.ensureHostPermission();
  assert.equal(b.calls.perms.length, 1);
});

test('menus are created with the configured name', () => {
  const { ctl, calls } = setup();
  ctl.setupMenus({ targetName: 'Studio' });
  assert.deepEqual(calls.menus, ['desk-send', 'desk-bring']);
});

test('manifest is valid for both browsers', () => {
  const m = require('../manifest.json');
  assert.equal(m.manifest_version, 3);
  assert.ok(m.background.service_worker && m.background.scripts.length);
  assert.deepEqual(m.host_permissions, ['http://127.0.0.1/*']);
  assert.equal(m.content_scripts, undefined, 'no script runs on every page');
  assert.ok(m.permissions.includes('activeTab') && m.permissions.includes('scripting'));
  assert.ok(!m.permissions.includes('tabs'));
  assert.ok(m.browser_specific_settings.gecko.id);
  const fs = require('node:fs'), path = require('node:path');
  for (const f of [...m.background.scripts, m.background.service_worker, 'src/core.js', 'src/content.js', m.options_ui.page])
    assert.ok(fs.existsSync(path.join(__dirname, '..', f)), f);
});

test('review round 2: hello carries a proof of the token, the placer is never asked to prove first', async () => {
  const { ctl, FakeWS } = setup();
  await ctl.connect();
  const ws = FakeWS.last;
  ws.onopen();
  await settle();
  const hello = ws.sentMsgs[0];
  assert.equal(hello.kind, 'hello');
  assert.equal(hello.proof, await hmac(TOKEN, core.helloProofInput(hello.cnonce)));
  assert.ok(!JSON.stringify(hello).includes(TOKEN));
});

test('review round 2: a short token is refused before any socket is opened', async () => {
  const { ctl, FakeWS } = setup({ token: 'short' });
  await ctl.connect();
  assert.equal(FakeWS.last, undefined);
  assert.match(ctl.status.lastError, /too short/);
});

test('review round 2: a tab for a local address waits for a click', async () => {
  const { ctl, calls, FakeWS } = setup();
  await login(ctl, FakeWS);
  const msg = (id, url) => JSON.stringify({ v: 1, kind: 'open-tab', id, tab: { url } });
  assert.equal(await ctl.handleIncoming(msg('a1', 'http://192.168.0.1/admin')), false);
  assert.equal(calls.created.length, 0, 'nothing opened without a click');
  assert.equal(calls.badge[calls.badge.length - 1], 'o');
  assert.equal(await ctl.openPending(), true);
  assert.equal(calls.created.length, 1);
  assert.equal(calls.created[0].url, 'http://192.168.0.1/admin');
  assert.equal(await ctl.openPending(), false, 'only once');
});

test('review round 2: at most ten tabs a minute open without a click', async () => {
  const { ctl, calls, FakeWS } = setup();
  await login(ctl, FakeWS);
  for (let i = 0; i < 14; i++) await ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'r' + i, tab: { url: 'https://example.com/' + i } }));
  assert.equal(calls.created.length, 10);
});

test('review round 2: seen ids and a held tab survive a worker restart', async () => {
  const a = setup();
  await login(a.ctl, a.FakeWS);
  await a.ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'same', tab: { url: 'https://example.com/' } }));
  const b = setup();
  Object.assign(b.sess, a.sess);
  await b.ctl.restoreState();
  await login(b.ctl, b.FakeWS);
  assert.equal(await b.ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'same', tab: { url: 'https://example.com/' } })), false);
  assert.equal(b.calls.created.length, 0, 'a repeat after a restart is dropped');
});

test('review round 2: restore waits for the page that was sent, not a redirect', async () => {
  const { ctl, calls, FakeWS } = setup();
  await login(ctl, FakeWS);
  await ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'rr', tab: { url: 'https://example.com/a', scrollY: 40 } }));
  await ctl.onTabUpdated(99, { status: 'complete' }, { url: 'https://login.other.test/' });
  assert.equal(calls.sent.filter((s) => s[1] === 'desk-restore').length, 0, 'sign-in page does not consume the state');
  await ctl.onTabUpdated(99, { status: 'complete' }, { url: 'https://example.com/a' });
  assert.equal(calls.sent.filter((s) => s[1] === 'desk-restore').length, 1);
});

test('review round 2: the first click after the worker wakes waits for the handshake instead of failing', async () => {
  const { ctl, calls, FakeWS } = setup();
  const clicked = ctl.onActionClicked({ id: 7 });
  await settle();
  const ws = FakeWS.last;
  ws.onopen();
  await settle();
  const cnonce = ws.sentMsgs[0].cnonce, snonce = 'ee'.repeat(16);
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'challenge', snonce, proof: await hmac(TOKEN, core.serverProofInput(cnonce, snonce)) }) });
  await settle();
  ws.onmessage({ data: JSON.stringify({ v: 1, kind: 'ready' }) });
  assert.equal(await clicked, true);
  assert.equal(calls.fetch.length, 1);
});

test('review round 2: the permission request is the first call in a click handler', () => {
  const { ctl, calls } = setup({ noPerm: true });
  ctl.onActionClicked({ id: 7 });
  assert.equal(calls.perms.length, 1, 'request issued synchronously, before any await');
});
