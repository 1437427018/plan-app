// Service Worker：负责离线缓存，让 PWA 断网也能打开
const CACHE = 'pwa-demo-v1';
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-180.png'
];

// 安装时缓存所有资源
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

// 激活时清理旧缓存
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// 拦截请求：优先用缓存，没有再走网络
self.addEventListener('fetch', event => {
  event.respondWith(
    caches.match(event.request).then(hit =>
      hit || fetch(event.request).catch(() => caches.match('./index.html'))
    )
  );
});
