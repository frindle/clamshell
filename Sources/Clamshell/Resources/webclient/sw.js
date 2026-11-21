// Offline shell for the web client. The page is served by the Mac, so while
// the Mac restarts /client does not load at all. This worker keeps the last
// good copy of the client page and its scripts and serves them when the Mac
// does not answer, so the page can show its reconnect state and the
// "Unlock disk" link (the unlock meta tag is part of the cached page).
//
// - Network first: a Mac that answers always wins, so updates apply at once.
// - Only /client and /client/* GET requests are touched. The WebSocket, the
//   clipboard bridge never passes through here.
// - BUILD is filled in by the host when it serves this file (the app build),
//   so a new app version gets a new cache and the old one is deleted.
// - Kill switch: the host serves this file with KILL = true when
//   `defaults write com.frindle.clamshell webClientOfflineShell -bool NO`
//   is set; the worker then clears its caches and unregisters itself. The page
//   also unregisters it when opened as /client?nosw=1.
// This is a classic script, not a module: Firefox cannot load module workers everywhere.
// Nothing sensitive is cached: the pages hold no password, and the clipboard
// token is the one the Mac put in the last page (a stale one just fails).

const BUILD = '__BUILD__';
const KILL = '__KILL__' === 'true';
const CACHE_PREFIX = 'clamshell-shell-';
const CACHE = CACHE_PREFIX + BUILD;

function inScope(url, origin) {
  let u;
  try { u = new URL(url); } catch (e) { return false; }
  if (u.origin !== origin) return false;
  return u.pathname === '/client' || u.pathname === '/client/' || u.pathname.startsWith('/client/');
}

// sw.js itself is always fetched fresh (the browser does that for workers).
function cacheable(url) {
  const u = new URL(url);
  return !u.pathname.endsWith('/sw.js');
}

// The last good copy for this request: the file itself, or for a page load the cached /client page.
async function cached(request, cachesApi, cacheName) {
  const cache = await cachesApi.open(cacheName);
  const hit = await cache.match(keyFor(request.url));
  if (hit) return hit;
  if (request.mode === 'navigate') return cache.match('/client');
  return undefined;
}

async function respond(request, deps) {
  const { cachesApi, fetchFn, cacheName } = deps;
  let res;
  try {
    res = await fetchFn(request);
  } catch (err) {
    const hit = await cached(request, cachesApi, cacheName);
    if (hit) return hit;
    throw err;
  }
  if (res && res.ok && cacheable(request.url)) {
    const cache = await cachesApi.open(cacheName);
    // The page is requested as /client or /client/ with a query string at times; keep one copy.
    await cache.put(keyFor(request.url), res.clone());
  } else if (res && res.status >= 500) {
    // Through a tunnel or proxy a Mac that is down answers with the proxy's error page
    // (502, 503, 504, 52x, 530) instead of a network error: treat it the same way.
    // 4xx (a sign-in or a refusal) always passes through.
    const hit = await cached(request, cachesApi, cacheName);
    if (hit) return hit;
  }
  return res;
}

function keyFor(url) {
  const u = new URL(url);
  const p = u.pathname === '/client/' ? '/client' : u.pathname;
  return p;
}

async function dropOldCaches(cachesApi, keep) {
  const names = await cachesApi.keys();
  await Promise.all(names.filter((n) => n.startsWith(CACHE_PREFIX) && n !== keep).map((n) => cachesApi.delete(n)));
}

if (typeof self !== 'undefined' && self.registration) {
  self.addEventListener('install', (e) => { e.waitUntil(self.skipWaiting()); });
  self.addEventListener('activate', (e) => {
    e.waitUntil((async () => {
      if (KILL) {
        const names = await caches.keys();
        await Promise.all(names.filter((n) => n.startsWith(CACHE_PREFIX)).map((n) => caches.delete(n)));
        await self.registration.unregister();
        return;
      }
      await dropOldCaches(caches, CACHE);
      await self.clients.claim();
    })());
  });
  self.addEventListener('fetch', (e) => {
    const req = e.request;
    if (KILL || req.method !== 'GET' || !inScope(req.url, self.location.origin)) return;
    e.respondWith(respond(req, { cachesApi: caches, fetchFn: fetch, cacheName: CACHE }));
  });
}
