// Service Worker：离线缓存，让 PWA 断网也能打开
const CACHE = 'planapp-v6';
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-180.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const isPage = req.mode === 'navigate'
    || req.url.endsWith('/')
    || req.url.endsWith('/index.html');

  // 页面本身：网络优先。改完代码刷新就能看到，不用手动升缓存版本；
  // 断网时才回退到缓存，保证离线还能打开。
  if (isPage) {
    event.respondWith(
      fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put('./index.html', copy)).catch(() => {});
        return res;
      }).catch(() => caches.match('./index.html'))
    );
    return;
  }

  // 图标 / manifest 这类静态资源：缓存优先，几乎不变
  event.respondWith(
    caches.match(req).then(hit =>
      hit || fetch(req).catch(() => caches.match('./index.html'))
    )
  );
});
