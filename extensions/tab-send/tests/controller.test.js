const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../src/core.js');
const { createController } = require('../src/controller.js');

function setup(over) {
  const calls = { fetch: [], created: [], sent: [], badge: [], timers: [] };
  const tabs = { 7: { id: 7, url: 'https://a.test/p', title: 'P' } };
  const api = {
    tabs: {
      get: async (id) => tabs[id],
      query: async () => [tabs[7]],
      create: async (o) => { calls.created.push(o); return { id: 99 }; },
      sendMessage: async (id, msg) => { calls.sent.push([id, msg.type]); if (over && over.noContent) throw new Error('no receiver'); return msg.type === 'desk-collect' ? { scrollX: 0, scrollY: 40, media: null } : undefined; },
    },
    action: { setBadgeText: (b) => calls.badge.push(b.text) },
    contextMenus: { removeAll: (cb) => cb(), create: (o) => (calls.menus = (calls.menus || []).concat(o.id)) },
  };
  class FakeWS { constructor(u) { this.url = u; this.sentMsgs = []; FakeWS.last = this; } send(m) { this.sentMsgs.push(m); } }
  const ctl = createController({
    api, core,
    fetchFn: async (u, i) => { calls.fetch.push([u, JSON.parse(i.body)]); return { ok: !(over && over.fail), status: over && over.fail ? 500 : 200 }; },
    WebSocketCtor: FakeWS,
    getSettings: async () => ({ port: 6000, token: 'tk' }),
    now: () => 1000,
    setTimeoutFn: (fn, ms) => { calls.timers.push(ms); return calls.timers.length; },
    random: () => 0,
  });
  return { ctl, calls, FakeWS };
}

test('send tab collects page state and posts it', async () => {
  const { ctl, calls } = setup();
  assert.equal(await ctl.sendTab(7), true);
  const [url, body] = calls.fetch[0];
  assert.equal(url, 'http://127.0.0.1:6000/v1/tab-send');
  assert.equal(body.tab.scrollY, 40);
  assert.equal(body.tab.sentAt, 1000);
});

test('a page without the content script still sends its address', async () => {
  const { ctl, calls } = setup({ noContent: true });
  assert.equal(await ctl.sendTab(7), true);
  assert.equal(calls.fetch[0][1].tab.scrollY, 0);
});

test('placer failure sets the error badge and reports false', async () => {
  const { ctl, calls } = setup({ fail: true });
  assert.equal(await ctl.sendTab(7), false);
  assert.deepEqual(calls.badge, ['!']);
  assert.match(ctl.status.lastError, /500/);
});

test('send-active-tab request from the placer sends the focused tab', async () => {
  const { ctl, calls } = setup();
  assert.equal(await ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'send-active-tab', id: 'r1' })), true);
  assert.equal(calls.fetch.length, 1);
});

test('open-tab creates a tab once, restores after load, and ignores a repeat', async () => {
  const { ctl, calls } = setup();
  const msg = JSON.stringify({ v: 1, kind: 'open-tab', id: 'm1', tab: { url: 'https://a.test/x', scrollY: 300 } });
  assert.equal(await ctl.handleIncoming(msg), true);
  assert.equal(await ctl.handleIncoming(msg), false);
  assert.deepEqual(calls.created, [{ url: 'https://a.test/x', active: true }]);
  ctl.onTabUpdated(99, { status: 'loading' });
  assert.equal(calls.sent.length, 0);
  ctl.onTabUpdated(99, { status: 'complete' });
  ctl.onTabUpdated(99, { status: 'complete' });
  assert.deepEqual(calls.sent, [[99, 'desk-restore']]);
});

test('hostile open-tab is dropped', async () => {
  const { ctl, calls } = setup();
  assert.equal(await ctl.handleIncoming(JSON.stringify({ v: 1, kind: 'open-tab', id: 'z', tab: { url: 'javascript:alert(1)' } })), false);
  assert.equal(calls.created.length, 0);
});

test('socket says hello on open, reconnects with backoff after close', async () => {
  const { ctl, calls, FakeWS } = setup();
  await ctl.connect();
  const ws1 = FakeWS.last;
  assert.equal(ws1.url, 'ws://127.0.0.1:6000/v1/tab-events');
  ws1.onopen();
  assert.deepEqual(JSON.parse(ws1.sentMsgs[0]), { v: 1, kind: 'hello', token: 'tk' });
  ws1.onclose();
  ws1.onclose();
  assert.deepEqual(calls.timers, [1000]); // one timer even if close fires twice
  ws1.onopen && ws1.onopen();
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
  assert.ok(m.host_permissions.every((h) => h.startsWith('http://127.0.0.1')));
  assert.ok(m.browser_specific_settings.gecko.id);
  const fs = require('node:fs'), path = require('node:path');
  for (const f of [...m.background.scripts, m.background.service_worker, ...m.content_scripts[0].js, m.options_ui.page])
    assert.ok(fs.existsSync(path.join(__dirname, '..', f)), f);
});
