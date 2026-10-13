/* XizmatGo offline shell. Supabase/API requests are intentionally never cached. */
const CACHE_NAME = "xizmatgo-shell-v2";
const SHELL = [
  "./",
  "./index.html",
  "./app.html",
  "./customer.html",
  "./specialist.html",
  "./public/favicon.svg",
  "./public/app-icon.svg",
  "./app.webmanifest"
];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === "navigate") {
    event.respondWith(fetch(request).then(response => {
      if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
      return response;
    }).catch(async () => (await caches.match(request)) || (await caches.match(url.pathname.endsWith("/app.html") ? "./app.html" : "./index.html"))));
    return;
  }
  event.respondWith(caches.match(request).then(cached => cached || fetch(request).then(response => {
    if (response.ok && url.pathname.includes("/public/")) caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
    return response;
  })));
});