// Tests for webclient/sw.js, the offline shell: runs the worker script in a
// fake worker global and drives its fetch handler. No browser, no network.
import { test } from 'node:test';
import assert from 'node:assert';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';

const SRC = readFileSync(new URL('../Sources/Clamshell/Resources/webclient/sw.js', import.meta.url), 'utf8');
const ORIGIN = 'http://mac.test:5901';

class FakeCache {
  constructor() { this.map = new Map(); }
  async put(k, v) { this.map.set(k, v); }
  async match(k) { return this.map.get(k); }
}
function makeWorker({ build = '1.0-1', kill = false, online = true } = {}) {
  const stores = new Map();
  const listeners = {};
  let unregistered = false;
  const caches = {
    open: async (n) => { if (!stores.has(n)) stores.set(n, new FakeCache()); return stores.get(n); },
    keys: async () => [...stores.keys()],
    delete: async (n) => stores.delete(n),
  };
  const state = { online, ok: true, fetched: [] };
  const mkRes = (body) => ({ ok: state.ok, body, clone() { return this; } });
  const self = {
    registration: { unregister: async () => { unregistered = true; } },
    location: { origin: ORIGIN },
    clients: { claim: async () => {} },
    skipWaiting: async () => {},
    addEventListener: (t, f) => { listeners[t] = f; },
  };
  const ctx = vm.createContext({
    self, caches, URL, console,
    fetch: async (req) => {
      state.fetched.push(req.url);
      if (!state.online) throw new TypeError('network down');
      return mkRes('live:' + new URL(req.url).pathname);
    },
  });
  vm.runInContext(SRC.replace("'__BUILD__'", `'${build}'`).replace("'__KILL__'", `'${kill}'`), ctx);
  const request = (path, extra = {}) => ({ url: ORIGIN + path, method: 'GET', mode: 'cors', ...extra });
  const fire = async (req) => {
    let p = null;
    listeners.fetch({ request: req, respondWith: (x) => { p = x; } });
    return p === null ? null : p;
  };
  const wait = async (type) => { let p; listeners[type]({ waitUntil: (x) => { p = x; } }); await p; };
  return { stores, state, request, fire, wait, unregistered: () => unregistered, listeners };
}

test('a live Mac is served live and the page is cached', async () => {
  const w = makeWorker();
  const res = await w.fire(w.request('/client', { mode: 'navigate' }));
  assert.strictEqual(res.body, 'live:/client');
  assert.ok(w.stores.get('clamshell-shell-1.0-1').map.has('/client'));
});

test('when the Mac is down the cached page and scripts are served', async () => {
  const w = makeWorker();
  await w.fire(w.request('/client', { mode: 'navigate' }));
  await w.fire(w.request('/client/client.js'));
  w.state.online = false;
  assert.strictEqual((await w.fire(w.request('/client', { mode: 'navigate' }))).body, 'live:/client');
  assert.strictEqual((await w.fire(w.request('/client/client.js'))).body, 'live:/client/client.js');
  // /client/ and a query string map to the same cached page.
  assert.strictEqual((await w.fire(w.request('/client/?x=1', { mode: 'navigate' }))).body, 'live:/client');
});

test('a navigation falls back to the cached shell; a script never cached rejects', async () => {
  const w = makeWorker();
  await w.fire(w.request('/client', { mode: 'navigate' }));
  w.state.online = false;
  assert.strictEqual((await w.fire(w.request('/client?display=b', { mode: 'navigate' }))).body, 'live:/client');
  await assert.rejects(w.fire(w.request('/client/never-seen.js')));
});

test('with nothing cached and the Mac down, the error passes through', async () => {
  const w = makeWorker({ online: false });
  await assert.rejects(w.fire(w.request('/client', { mode: 'navigate' })));
});

test('only /client is handled: other paths, origins and methods are left alone', async () => {
  const w = makeWorker();
  assert.strictEqual(await w.fire(w.request('/clipboard?token=x')), null);
  assert.strictEqual(await w.fire(w.request('/vnc.html')), null);
  assert.strictEqual(await w.fire(w.request('/clientele')), null);
  assert.strictEqual(await w.fire({ url: 'http://other.test/client', method: 'GET' }), null);
  assert.strictEqual(await w.fire(w.request('/client', { method: 'POST' })), null);
  assert.deepStrictEqual(w.state.fetched, []);
});

test('sw.js itself is never cached', async () => {
  const w = makeWorker();
  await w.fire(w.request('/client/sw.js'));
  assert.strictEqual(w.stores.get('clamshell-shell-1.0-1').map.size, 0);
});

test('a failed response is not cached and passes through', async () => {
  const w = makeWorker();
  w.state.ok = false;
  const res = await w.fire(w.request('/client', { mode: 'navigate' }));
  assert.strictEqual(res.ok, false);
  assert.strictEqual(w.stores.get('clamshell-shell-1.0-1').map.size, 0);
});

test('activating a new build deletes the old build caches only', async () => {
  const w = makeWorker({ build: '2.0-5' });
  w.stores.set('clamshell-shell-1.0-1', new FakeCache());
  w.stores.set('unrelated', new FakeCache());
  await w.wait('activate');
  assert.deepStrictEqual([...w.stores.keys()].sort(), ['unrelated']);
});

test('kill switch: no interception, caches cleared, worker unregisters', async () => {
  const w = makeWorker({ kill: true });
  w.stores.set('clamshell-shell-1.0-1', new FakeCache());
  assert.strictEqual(await w.fire(w.request('/client', { mode: 'navigate' })), null);
  await w.wait('activate');
  assert.strictEqual(w.unregistered(), true);
  assert.deepStrictEqual([...w.stores.keys()], []);
});

test('the served worker has its placeholders for the host to fill', () => {
  assert.ok(SRC.includes("'__BUILD__'") && SRC.includes("'__KILL__'"));
});
