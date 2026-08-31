/* ===== Pro Keys — Shared UI helpers =====
 * Used by index.html and dashboard.html (and any future page) so the
 * icon-rendering logic lives in ONE place instead of being copy-pasted
 * per file. Fixing a bug here fixes it everywhere that includes this file.
 *
 * Include with: <script src="shared/pk-shared.js"></script>
 * (must load AFTER the page defines its own ICON_SIZE_MAP, if any)
 */
window.PK = window.PK || {};

/**
 * Applies admin-uploaded icons/sizes to every [data-icon-key] element on
 * the page. Falls back to the element's original inline content (emoji or
 * SVG already in the HTML) if no override exists, or if the uploaded image
 * fails to load / loads empty.
 *
 * @param {Function} getOverrides - returns { icons, iconSizes } (read fresh
 *   each call, since these objects get replaced after the async DB fetch).
 * @param {Object} sizeMap - per-key default px size, e.g. { logo_index: '46px' }.
 * @param {string[]} [extraLogoKeys] - keys (besides anything starting with
 *   "logo" or "site_favicon") that should preserve aspect ratio (height
 *   fixed, width auto) instead of being forced square.
 */
PK.applyIcons = function (getOverrides, sizeMap, extraLogoKeys) {
  const overrides = getOverrides() || {};
  const icons = overrides.icons || {};
  const sizes = overrides.iconSizes || {};
  const logoKeys = new Set(['site_favicon', ...(extraLogoKeys || [])]);

  document.querySelectorAll('[data-icon-key]').forEach((el) => {
    const key = el.dataset.iconKey;
    const url = icons[key];
    const overridePx = sizes[key];
    const size = (overridePx ? overridePx + 'px' : null) || sizeMap[key] || '18px';
    const isLogo = key.indexOf('logo') === 0 || logoKeys.has(key);

    if (url) {
      if (el.tagName === 'IMG') {
        el.src = url;
        if (isLogo) {
          /* Logo fills its container width, height auto-scales (supports GIF) */
          el.style.width = '100%';
          el.style.maxHeight = size;
          el.style.height = 'auto';
          el.style.objectFit = 'contain';
        } else { el.style.width = size; el.style.height = size; }
      } else {
        const img = document.createElement('img');
        img.src = url;
        img.alt = key;
        img.style.cssText = isLogo
          ? `width:100%;max-height:${size};height:auto;object-fit:contain;display:block;`
          : `width:${size};height:${size};object-fit:contain;flex:none;display:inline-block;vertical-align:middle;border-radius:6px;`;
        // If the uploaded file is broken or loads empty, keep the original
        // fallback content instead of showing a blank icon.
        img.onerror = () => { img.replaceWith(el); };
        img.onload = () => { if (!img.naturalWidth) img.replaceWith(el); };
        el.replaceWith(img);
      }
    } else if (overridePx) {
      el.style.width = size;
      el.style.height = size;
      if (el.tagName === 'SPAN') el.style.fontSize = size;
    }
  });
};

/**
 * The part of "switch language" that's identical on every page: flip
 * dir/lang on <html> and translate every [data-i18n] element. Page-specific
 * re-rendering (order tables, prices, notifications, etc.) stays in each
 * page's own applyLang() and runs after calling this.
 *
 * @param {string} currentLang - 'ar' | 'en'
 * @param {Function} t - translation lookup fn, t(key) -> string
 */
PK.translateDom = function (currentLang, t) {
  const html = document.getElementById('htmlRoot') || document.documentElement;
  html.setAttribute('dir', currentLang === 'ar' ? 'rtl' : 'ltr');
  html.setAttribute('lang', currentLang);
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-ph]').forEach((el) => {
    el.setAttribute('placeholder', t(el.dataset.i18nPh));
  });
};
