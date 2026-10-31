/* Service worker della dashboard: avvisa il titolare delle prenotazioni anche ad app chiusa.
   Non mette in cache niente. */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener("push", function (e) {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (er) { d = { body: e.data ? e.data.text() : "" }; }
  // il segnale sull'icona dell'app: il numero giusto lo rimette la dashboard appena si apre
  if (self.navigator.setAppBadge) self.navigator.setAppBadge().catch(function () {});
  e.waitUntil(self.registration.showNotification(d.title || "Vico Dashboard", {
    body: d.body || "",
    icon: "../assets/img/icona-titolare-192.png",
    badge: "../assets/img/icona-titolare-192.png",
    tag: d.tag || "vico-dashboard",
    renotify: true,
    data: { url: d.url || "./" },
    vibrate: [200, 100, 200],
  }));
});

// tocco sulla notifica: apre (o riporta in primo piano) la dashboard sulla scheda Prenota
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (finestre) {
    const aperta = finestre.find(function (c) { return c.url.indexOf(self.registration.scope) === 0; });
    if (aperta) return aperta.navigate(url).then(function (c) { return (c || aperta).focus(); });
    return self.clients.openWindow(url);
  }));
});
