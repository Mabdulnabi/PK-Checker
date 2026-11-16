// Meta Pixel for the public pages (home and sign-in). Same pixel and the same cookie consent as the
// dashboard: nothing loads until the visitor accepts, and the choice is shared across the site.
(function(){
  var PIXEL_ID = '1174873375104920';
  var KEY = 'pk-cookie-consent';
  var CLICK_KEY = 'pk-fbclid';

  // An ad click arrives with ?fbclid=... . Keep it for this tab so the visit can still be credited
  // to the ad if the visitor accepts cookies on a later page (the pixel itself only reads the URL).
  try {
    var m = location.search.match(/[?&]fbclid=([^&#]+)/);
    if (m) sessionStorage.setItem(CLICK_KEY, JSON.stringify({ id: decodeURIComponent(m[1]), t: Date.now() }));
  } catch (e) {}

  function hasCookie(name){ return document.cookie.split('; ').some(function(c){ return c.indexOf(name + '=') === 0; }); }
  // Sets Meta's click cookie (_fbc, format fb.1.<time>.<fbclid>) from the saved click, if the pixel can't.
  function restoreClick(){
    try {
      if (hasCookie('_fbc') || /[?&]fbclid=/.test(location.search)) return;
      var saved = JSON.parse(sessionStorage.getItem(CLICK_KEY) || 'null');
      if (!saved || !saved.id) return;
      document.cookie = '_fbc=fb.1.' + saved.t + '.' + saved.id + '; path=/; max-age=' + (90 * 86400) + '; SameSite=Lax' + (location.protocol === 'https:' ? '; Secure' : '');
    } catch (e) {}
  }

  function loadPixel(){
    if (window.fbq) return;
    restoreClick();
    !function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?n.callMethod.apply(n,arguments):n.queue.push(arguments)};if(!f._fbq)f._fbq=n;n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,document,'script','https://connect.facebook.net/en_US/fbevents.js');
    fbq('init', PIXEL_ID);
    fbq('track', 'PageView');
  }
  // Same helper name as the dashboard. Does nothing without consent.
  window.pkTrack = function(event, params){
    if (window.fbq && localStorage.getItem(KEY) === 'yes') fbq('track', event, params || {});
  };

  function banner(){
    if (document.getElementById('pkCookieBanner')) return;
    var ar = (localStorage.getItem('prokeys-lang') || 'ar') !== 'en';
    var box = document.createElement('div');
    box.id = 'pkCookieBanner';
    box.setAttribute('style', 'position:fixed;left:12px;right:12px;bottom:12px;z-index:99999;max-width:560px;margin:auto;background:#fff;color:#1B2556;border:1px solid #DCE4F1;border-radius:14px;box-shadow:0 12px 32px rgba(27,37,86,.18);padding:14px 16px;font-family:Cairo,sans-serif;font-size:13px;line-height:1.6;display:flex;gap:12px;align-items:center;flex-wrap:wrap;direction:' + (ar ? 'rtl' : 'ltr') + ';');
    box.innerHTML = '<div style="flex:1;min-width:200px;">' + (ar
        ? 'بنستخدم كوكيز لقياس الإعلانات وتحسين تجربتك. تقدر ترفض.'
        : 'We use cookies to measure ads and improve your experience. You can decline.') + '</div>' +
      '<div style="display:flex;gap:8px;">' +
        '<button id="pkCkNo" type="button" style="padding:8px 14px;border-radius:9px;border:1.5px solid #DCE4F1;background:#fff;color:#6B7494;font-family:Cairo,sans-serif;font-weight:700;cursor:pointer;">' + (ar ? 'رفض' : 'Decline') + '</button>' +
        '<button id="pkCkYes" type="button" style="padding:8px 14px;border-radius:9px;border:none;background:#0E7AFE;color:#fff;font-family:Cairo,sans-serif;font-weight:700;cursor:pointer;">' + (ar ? 'موافق' : 'Accept') + '</button>' +
      '</div>';
    document.body.appendChild(box);
    document.getElementById('pkCkYes').onclick = function(){ localStorage.setItem(KEY, 'yes'); box.remove(); loadPixel(); };
    document.getElementById('pkCkNo').onclick = function(){ localStorage.setItem(KEY, 'no'); box.remove(); };
  }

  var choice = localStorage.getItem(KEY);
  if (choice === 'yes') loadPixel();
  else if (choice !== 'no') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', banner);
    else banner();
  }
})();
