/* Service worker dell'app agente: riceve le notifiche anche ad app chiusa.
   Non mette in cache niente. */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener("push", function (e) {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (er) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Vico Agenti", {
    body: d.body || "",
    icon: "../assets/img/logo.jpg",
    badge: "../assets/img/logo.jpg",
    tag: d.tag || "vico-agenti",
    renotify: true,
    vibrate: [200, 100, 200, 100, 300],
  }));
});

self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (finestre) {
    const aperta = finestre.find(function (c) { return c.url.indexOf(self.registration.scope) === 0; });
    if (aperta) return aperta.focus();
    return self.clients.openWindow(self.registration.scope);
  }));
});
