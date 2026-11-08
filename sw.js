// Admin push notifications. Shows each event as a system notification, and opens the admin on click.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'PK Checker', body: event.data ? event.data.text() : '' };
  }
  event.waitUntil(self.registration.showNotification(data.title || 'PK Checker Admin', {
    body: data.body || '',
    icon: '/admin-icon-192.png',
    badge: '/admin-icon-192.png',
    tag: data.tag || undefined,
    renotify: !!data.tag,
    dir: 'rtl',
    lang: 'ar',
    data: { url: data.url || '/admin-dashboard.html' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/admin-dashboard.html';
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of all) {
      if ('focus' in client) {
        if ('navigate' in client) await client.navigate(url).catch(() => {});
        return client.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
