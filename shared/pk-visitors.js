/* Visitor counter: a live number from the site_visitor_counter table (Supabase).
   - Counts at most one visit per browser per day (localStorage 'pk-visit-day').
   - Every element with [data-pkv-num] shows the number and is refreshed every 60 seconds.
   - Loaded at the end of the page, after the page's supabaseClient is created. */
(function () {
  var DAY_KEY = 'pk-visit-day';
  var REFRESH_MS = 60000;

  function injectStyle() {
    if (document.getElementById('pkv-style')) return;
    var s = document.createElement('style');
    s.id = 'pkv-style';
    s.textContent = [
      '.pkv-badge{display:inline-flex;align-items:center;gap:8px;padding:7px 14px;border-radius:999px;',
      'background:linear-gradient(135deg,rgba(255,255,255,.62),rgba(255,255,255,.22));',
      'backdrop-filter:blur(14px) saturate(160%);-webkit-backdrop-filter:blur(14px) saturate(160%);',
      'border:1px solid rgba(255,255,255,.7);',
      'box-shadow:0 8px 24px -10px rgba(27,37,86,.38),inset 0 1px 0 rgba(255,255,255,.8);',
      'color:#1B2556;font-family:"Cairo",sans-serif;font-size:12.5px;font-weight:700;white-space:nowrap;}',
      '.pkv-dot{width:7px;height:7px;border-radius:50%;background:#0E9F6E;box-shadow:0 0 0 3px rgba(14,159,110,.22);flex:none;}',
      '.pkv-num{font-family:"Space Grotesk",sans-serif;font-variant-numeric:tabular-nums;font-weight:800;color:#1B2556;min-width:1ch;}',
      '.pkv-lbl-en{display:none;}',
      'html[dir="ltr"] .pkv-lbl-ar{display:none;}',
      'html[dir="ltr"] .pkv-lbl-en{display:inline;}',
      '.pkv-wrap{display:flex;justify-content:center;width:100%;margin-top:14px;}',
      '.pkv-copy{display:block;}',
      '.pkv-side{display:flex;justify-content:center;margin:0 0 10px;}',
      '.pkv-title{text-align:center;font-family:"Cairo",sans-serif;font-size:13.5px;font-weight:700;color:#1B2556;padding:4px 0 2px;}',
      '.pkv-title .pkv-code{color:#2563EB;font-weight:800;}',
      '.pkv-title b{color:#2563EB;font-weight:800;}',
      '.pkv-title .pkv-link{color:inherit;text-decoration:none;}',
      '[data-theme="dark"] .pkv-title{color:#e8eff5;}',
      '[data-theme="dark"] .pkv-title .pkv-code,[data-theme="dark"] .pkv-title b{color:#7fb0ff;}',
      '[data-theme="dark"] .pkv-badge{background:linear-gradient(135deg,rgba(255,255,255,.14),rgba(255,255,255,.04));color:#e8eff5;border-color:rgba(255,255,255,.2);}',
      '[data-theme="dark"] .pkv-num{color:#ffffff;}',
      '@keyframes pkvPulse{0%,100%{box-shadow:0 0 0 3px rgba(14,159,110,.22);}50%{box-shadow:0 0 0 6px rgba(14,159,110,.05);}}',
      '.pkv-dot{animation:pkvPulse 2s ease-in-out infinite;}'
    ].join('');
    document.head.appendChild(s);
  }

  function today() {
    var d = new Date();
    return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
  }

  function show(value) {
    var txt = Number(value || 0).toLocaleString('en-US');
    document.querySelectorAll('[data-pkv-num]').forEach(function (el) { el.textContent = txt; });
  }

  async function hitOncePerDay(client) {
    try {
      if (localStorage.getItem(DAY_KEY) === today()) return;
      var r = await client.rpc('visitor_count_hit');
      localStorage.setItem(DAY_KEY, today());
      if (!r.error && r.data != null) show(r.data);
    } catch (e) { /* the counter is optional: never break the page */ }
  }

  async function refresh(client) {
    try {
      var r = await client.rpc('visitor_count_get');
      if (!r.error && r.data != null) show(r.data);
    } catch (e) { /* keep the last shown value */ }
  }

  function mount(client) {
    if (!client || !document.querySelector('[data-pkv-num]')) return;
    injectStyle();
    hitOncePerDay(client).then(function () { refresh(client); });
    setInterval(function () { refresh(client); }, REFRESH_MS);
  }

  if (typeof supabaseClient !== 'undefined') mount(supabaseClient);
  window.PKVisitors = { mount: mount };
})();
