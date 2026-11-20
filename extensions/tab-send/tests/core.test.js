const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../src/core.js');

test('only http and https urls are sendable', () => {
  for (const ok of ['http://a.test/', 'https://a.test/x?y=1#z']) assert.equal(core.isSendableUrl(ok), true, ok);
  for (const bad of ['', 'about:blank', 'javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', 'moz-extension://x/y', 'chrome://settings', 'ftp://a', 'not a url', null, 5, 'https://a.test/' + 'x'.repeat(9000)])
    assert.equal(core.isSendableUrl(bad), false, String(bad).slice(0, 30));
});

test('payload carries url, title, scroll and media; clamps junk', () => {
  const p = core.buildPayload({ url: 'https://a.test/', title: 'T'.repeat(900) }, { scrollX: 3, scrollY: 120.5, media: { time: 61.2, playing: true } }, 42);
  assert.equal(p.url, 'https://a.test/');
  assert.equal(p.title.length, core.MAX_TITLE);
  assert.deepEqual([p.scrollX, p.scrollY, p.sentAt], [3, 120.5, 42]);
  assert.deepEqual(p.media, { time: 61.2, playing: true });
  const q = core.buildPayload({ url: 'https://a.test/' }, { scrollY: -5, scrollX: NaN, media: { time: -1 } }, 1);
  assert.deepEqual([q.scrollX, q.scrollY, q.media, q.title], [0, 0, null, '']);
  assert.equal(core.buildPayload({ url: 'about:blank' }, {}, 1), null);
  assert.equal(core.buildPayload(null, {}, 1), null);
  assert.equal(core.buildPayload({ url: 'https://a.test/' }, undefined, 1).scrollY, 0);
});

test('settings are normalized', () => {
  assert.deepEqual(core.normalizeSettings(undefined), { port: 5911, token: '', targetName: 'the other Mac' });
  assert.equal(core.normalizeSettings({ port: 80 }).port, 5911);
  assert.equal(core.normalizeSettings({ port: 6000.5 }).port, 5911);
  assert.equal(core.normalizeSettings({ port: 6000, token: 't', targetName: '  Studio ' }).targetName, 'Studio');
  assert.equal(core.normalizeSettings({ targetName: '   ' }).targetName, 'the other Mac');
});

test('requests go to loopback only, with the token as a header', () => {
  const s = core.normalizeSettings({ port: 6000, token: 'abc' });
  const r = core.buildSendRequest(s, { url: 'https://a.test/' });
  assert.equal(r.url, 'http://127.0.0.1:6000/v1/tab-send');
  assert.equal(r.init.method, 'POST');
  assert.equal(r.init.headers.Authorization, 'Bearer abc');
  assert.deepEqual(JSON.parse(r.init.body), { v: 1, kind: 'send', tab: { url: 'https://a.test/' } });
  assert.equal(core.buildSendRequest(core.normalizeSettings({}), {}).init.headers.Authorization, undefined);
  assert.deepEqual(JSON.parse(core.buildBringRequest(s).init.body), { v: 1, kind: 'bring' });
  assert.equal(core.wsUrl(s), 'ws://127.0.0.1:6000/v1/tab-events');
  assert.ok(!core.wsUrl(s).includes('abc'), 'token must not be in the url');
  assert.deepEqual(JSON.parse(core.buildHello(s)), { v: 1, kind: 'hello', token: 'abc' });
});

test('incoming messages: valid, malformed, hostile', () => {
  const open = { v: 1, kind: 'open-tab', id: 'm1', tab: { url: 'https://a.test/', title: 'x', scrollY: 10, media: { time: 5, playing: false } } };
  const m = core.parseIncoming(JSON.stringify(open));
  assert.equal(m.kind, 'open-tab');
  assert.equal(m.tab.scrollY, 10);
  assert.deepEqual(m.tab.media, { time: 5, playing: false });
  assert.deepEqual(core.parseIncoming({ v: 1, kind: 'send-active-tab', id: 'q' }), { kind: 'send-active-tab', id: 'q' });
  const bads = ['{', 'null', '[]', '5', JSON.stringify({ ...open, v: 2 }), JSON.stringify({ ...open, id: '' }),
    JSON.stringify({ ...open, id: undefined }), JSON.stringify({ ...open, tab: { url: 'javascript:alert(1)' } }),
    JSON.stringify({ ...open, tab: null }), JSON.stringify({ ...open, kind: 'eval' }), JSON.stringify({ v: 1, kind: 'send-active-tab' })];
  for (const b of bads) assert.equal(core.parseIncoming(b), null, b);
});

test('backoff doubles, caps, jitters downward, resets', () => {
  const b = new core.Backoff({ base: 1000, max: 8000 });
  assert.deepEqual([0, 0, 0, 0, 0].map(() => b.next(0)), [1000, 2000, 4000, 8000, 8000]);
  b.reset();
  assert.equal(b.next(1), 800);
  assert.equal(b.next(99), 1600); // jitter clamped to 1
});

test('seen ignores repeats and forgets old ids', () => {
  const s = new core.Seen(2);
  assert.equal(s.check('a'), true);
  assert.equal(s.check('a'), false);
  s.check('b'); s.check('c');
  assert.equal(s.check('a'), true);
});

function fakeDoc(els) { return { querySelectorAll: () => els }; }

test('collectPageState picks the playing media, else the first usable', () => {
  const win = { scrollX: 1, scrollY: 200 };
  const paused = { duration: 100, currentTime: 10, paused: true, ended: false };
  const playing = { duration: 50, currentTime: 7, paused: false, ended: false };
  assert.deepEqual(core.collectPageState(win, fakeDoc([paused, playing])), { scrollX: 1, scrollY: 200, media: { time: 7, playing: true } });
  assert.deepEqual(core.collectPageState(win, fakeDoc([paused])).media, { time: 10, playing: false });
  assert.equal(core.collectPageState(win, fakeDoc([{ duration: NaN }])).media, null);
  assert.equal(core.collectPageState(win, fakeDoc([])).media, null);
});

test('applyPageState sets media and retries scroll until the page is tall enough', async () => {
  let height = 0; // grows as the page loads
  const win = { scrollX: 0, scrollY: 0, scrollTo(x, y) { this.scrollX = x; this.scrollY = Math.min(y, height); } };
  let played = 0;
  const el = { duration: 100, currentTime: 0, paused: true, ended: false, play() { played++; return Promise.reject(new Error('blocked')); } };
  const queue = [];
  const schedule = (fn) => { height += 300; queue.push(fn); setImmediate(() => queue.shift()()); };
  const r = await core.applyPageState(win, fakeDoc([el]), { scrollX: 0, scrollY: 900, media: { time: 33, playing: true } }, schedule);
  assert.deepEqual(r, { scrolled: true, media: true });
  assert.equal(el.currentTime, 33);
  assert.equal(played, 1);
  assert.equal(win.scrollY, 900);
});

test('applyPageState gives up after the retry budget', async () => {
  const win = { scrollX: 0, scrollY: 0, scrollTo() {} };
  let n = 0;
  const r = await core.applyPageState(win, fakeDoc([]), { scrollX: 0, scrollY: 500, media: null }, (fn) => { n++; setImmediate(fn); }, { tries: 3 });
  assert.equal(r.scrolled, false);
  assert.equal(n, 2);
});
