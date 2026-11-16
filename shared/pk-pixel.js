// Meta Pixel for the public pages (home and sign-in). Same pixel as the dashboard; it loads for every
// visitor as the page opens.
(function(){
  var PIXEL_ID = '1174873375104920';
  var CLICK_KEY = 'pk-fbclid';

  // An ad click arrives with ?fbclid=... . Keep it for this tab, so the click cookie (_fbc) can be
  // restored on a later page if the browser lost it (the pixel itself only reads the URL).
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
  // Same helper name as the dashboard.
  window.pkTrack = function(event, params){
    if (window.fbq) fbq('track', event, params || {});
  };

  loadPixel();
})();
