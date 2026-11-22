/* Site activity for the admin Heatmap tab: where people click and how long they stay on each area.
   - Records: click position (x across the page 0..1, y in px from the top), the clicked button/link
     label, the current area (dashboard tab, or 'index' on the landing page), time on each area and
     how far the landing page was scrolled.
   - Never records typed text, input values, chat messages or table contents.
   - Sent in small batches through the log_site_events() database function.
   - Off on preview pages (?preview=1), used by the admin heatmap itself.
   Load it after the page's supabaseClient exists. Pages set the area with PKTrack.setArea('wallet'). */
(function () {
  if (new URLSearchParams(location.search).has('preview')) return;
  var PAGE = /dashboard/.test(location.pathname) ? 'dashboard' : 'index';
  var SID_KEY = 'pk-track-sid';
  var sid = sessionStorage.getItem(SID_KEY);
  if (!sid) { sid = Math.random().toString(36).slice(2) + Date.now().toString(36); sessionStorage.setItem(SID_KEY, sid); }
  // The dashboard's tab shown on load (it is shown without a tab switch, so read it from the page).
  function visibleTab() {
    var panes = document.querySelectorAll('.tabpane');
    for (var i = 0; i < panes.length; i++) if (panes[i].style.display === 'block' && panes[i].id.indexOf('pane-') === 0) return panes[i].id.slice(5);
    return 'new-check';
  }
  var area = PAGE === 'index' ? 'index' : visibleTab();
  var areaStart = Date.now();
  var maxScroll = 0;
  var queue = [];

  function client() { return typeof supabaseClient !== 'undefined' ? supabaseClient : null; }
  function push(ev) {
    ev.page = PAGE; ev.sid = sid; ev.vw = window.innerWidth;
    queue.push(ev);
    if (queue.length >= 40) flush();
  }
  function flush() {
    var c = client();
    if (!c || !queue.length) return;
    var batch = queue.splice(0, 60);
    try { c.rpc('log_site_events', { p_events: batch }).then(function () {}, function () {}); } catch (e) { /* optional */ }
  }
  function docHeight() { return Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0); }
  function scrollFrac() {
    var sc = typeof scroller === 'function' ? scroller() : null;
    if (sc) return sc.scrollHeight ? Math.min(1, (sc.scrollTop + sc.clientHeight) / sc.scrollHeight) : 0;
    var h = docHeight();
    return h ? Math.min(1, (window.scrollY + window.innerHeight) / h) : 0;
  }
  function endView() {
    var d = Math.round((Date.now() - areaStart) / 1000);
    if (d >= 1) push({ kind: 'view', area: area, dur: Math.min(d, 3600), y: +maxScroll.toFixed(3) });
    areaStart = Date.now();
  }
  function startView() { push({ kind: 'view', area: area, dur: 0 }); }

  // A short, safe name for what was clicked: a button/link label, never typed content.
  var PRIVATE = 'input, textarea, select, [contenteditable], .chat-window, #chatWindow, .chat-msg, table, [data-private]';
  function labelOf(target) {
    if (!target || !target.closest) return '';
    if (target.closest(PRIVATE)) {
      var tbl = target.closest('table');
      if (tbl && !target.closest('button, a')) return 'table' + (tbl.id ? ':' + tbl.id : '');
      if (target.closest('input, textarea, select')) {
        var f = target.closest('input, textarea, select');
        return 'field:' + (f.id || f.name || f.getAttribute('placeholder') || f.type || '').slice(0, 40);
      }
      if (!target.closest('button, a')) return '';
    }
    var el = target.closest('button, a, [onclick], .navtab, .paycard, [data-tab], [role="button"], label, summary, .plan-card, .ac-card, .ac-cat');
    if (!el) return '';
    var txt = (el.getAttribute('aria-label') || el.getAttribute('title') || el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    if (!txt) txt = el.dataset.tab || el.dataset.pay || el.id || el.tagName.toLowerCase();
    return txt.slice(0, 60);
  }

  // The dashboard scrolls inside .main-wrap (not the page): positions are measured from the top of
  // that area so they match the admin preview, which shows each tab at full height.
  function scroller() {
    if (PAGE !== 'dashboard') return null;
    var sc = document.querySelector('.main-wrap');
    return sc && sc.scrollHeight > sc.clientHeight + 4 && getComputedStyle(sc).overflowY !== 'visible' ? sc : null;
  }
  document.addEventListener('click', function (e) {
    var sc = scroller();
    var x = PAGE === 'dashboard' ? e.clientX / (window.innerWidth || 1) : e.pageX / (Math.max(document.documentElement.scrollWidth, window.innerWidth) || 1);
    var y = sc ? e.clientY + sc.scrollTop : e.pageY;
    push({ kind: 'click', area: area, x: +x.toFixed(4), y: Math.round(y), doc_h: sc ? sc.scrollHeight : docHeight(), label: labelOf(e.target) });
  }, { capture: true, passive: true });
  // capture: the dashboard's own scrolling area does not send scroll events to the window
  document.addEventListener('scroll', function () { var f = scrollFrac(); if (f > maxScroll) maxScroll = f; }, { capture: true, passive: true });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') { endView(); flush(); }
    else areaStart = Date.now();
  });
  window.addEventListener('pagehide', function () { endView(); flush(); });
  setInterval(flush, 15000);

  window.PKTrack = {
    setArea: function (a) {
      if (!a || a === area) return;
      endView();
      area = String(a).slice(0, 80);
      maxScroll = 0;
      setTimeout(function () { maxScroll = Math.max(maxScroll, scrollFrac()); }, 600);
      startView();
    },
    area: function () { return area; },
    flush: flush,
  };
  setTimeout(function () {
    if (PAGE === 'dashboard' && area === 'new-check' && window._pkArea && window._pkArea !== 'home') area = window._pkArea;
    maxScroll = scrollFrac(); startView();
  }, 800);
})();
