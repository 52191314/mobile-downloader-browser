(function() {
  // --- Aurora Channel Shim for flutter_inappwebview ---
  // Maps old webview_flutter API: ChannelName.postMessage(data)
  // To new flutter_inappwebview API: window.flutter_inappwebview.callHandler(name, data)
  if (!window.__auroraChannelShim) {
    window.__auroraChannelShim = true;
    var __auroraChannels = ['MediaSnifferChannel','MediaSniffer','MediaSnifferDataChannel','LinkContextChannel','AdBlockerChannel','IframeSrcChannel','PopupBlockerChannel','ElementPickerChannel','MediaMetaChannel','PageMetaChannel','TextSelectionChannel','HlsPlaylistChannel','NavigationSwipeChannel','AuroraPlayChannel','InvisibleRedirectChannel','VideoFloatChannel'];
    for (var __i = 0; __i < __auroraChannels.length; __i++) {
      (function(__name) {
        window[__name] = {
          postMessage: function(data) {
            try { window.flutter_inappwebview.callHandler(__name, data); } catch(_) {}
          }
        };
      })(__auroraChannels[__i]);
    }
  }

  // --- URL dedup cache ---
  // Prevents the same URL from being posted to Dart more than once.  Without
  // this, a busy page (e.g. Google search results) can flood the platform
  // channel with hundreds of identical messages.  Cleared when the entry
  // count exceeds 1000 to keep memory bounded.
  var _postedUrls = {};
  var _postedUrlsCount = 0;
  function postUrl(value) {
    if (!value) return;
    var key = String(value);
    if (_postedUrls[key]) return;
    _postedUrls[key] = true;
    if (++_postedUrlsCount > 1000) { _postedUrls = {}; _postedUrlsCount = 0; }
    try { MediaSnifferChannel.postMessage(key); } catch (_) {}
  }

  function normalizeUrl(value) {
    if (!value) return "";
    try { return new URL(String(value), document.baseURI).href; } catch (_) { return String(value || ""); }
  }

  function cleanIdent(value) {
    return String(value || "").replace(/[^a-zA-Z0-9_-]/g, "");
  }

  function textForElement(element) {
    if (!element) return "";
    var text = element.innerText || element.alt || element.title || element.getAttribute && element.getAttribute("aria-label") || "";
    return String(text || "").trim().replace(/\s+/g, " ").slice(0, 300);
  }

  function selectorForElement(element) {
    if (!element || !element.tagName) return "";
    var tag = element.tagName.toLowerCase();
    var id = cleanIdent(element.id);
    if (id) return "#" + id;
    var selector = tag;
    if (element.classList && element.classList.length) {
      var added = 0;
      for (var i = 0; i < element.classList.length && added < 3 && selector.length < 90; i++) {
        var className = cleanIdent(element.classList[i]);
        if (className) {
          selector += "." + className;
          added++;
        }
      }
    }
    // If we have only the bare tag, add the parent path so the CSS rule
    // doesn't accidentally match every element of that tag on the page.
    if (selector === tag) {
      var parent = element.parentElement;
      if (parent && parent !== document.body && parent !== document.documentElement) {
        var parentTag = parent.tagName.toLowerCase();
        var parentSel = parentTag;
        if (parent.classList && parent.classList.length) {
          for (var pi = 0; pi < parent.classList.length && parentSel.length < 80; pi++) {
            var pcn = cleanIdent(parent.classList[pi]);
            if (pcn) parentSel += "." + pcn;
          }
        }
        selector = parentSel + " > " + selector;
        // Only fall back to nth-of-type if parent has multiple same-tag children
        var siblings = parent.querySelectorAll(':scope > ' + tag);
        if (siblings.length > 1) {
          var index = 1;
          var sibling = element;
          while ((sibling = sibling.previousElementSibling)) {
            if (sibling.tagName === element.tagName) index++;
          }
          selector += ":nth-of-type(" + index + ")";
        }
      } else {
        // No useful parent - still skip nth-of-type so the rule applies broadly
        // to all matching elements of this type.
      }
    }
    return selector.slice(0, 120);
  }

  function contextForElement(target) {
    var element = target && target.nodeType === 1 ? target : target && target.parentElement;
    if (!element) element = document.body || document.documentElement;
    var link = element && element.closest ? element.closest("a[href]") : null;
    var media = element && element.closest ? element.closest("img[src],video,audio,source[src]") : null;
    var href = link ? normalizeUrl(link.getAttribute("href") || link.href || "") : "";
    var src = "";
    if (media) src = normalizeUrl(media.currentSrc || media.src || media.getAttribute("src") || "");
    if (!src && element) src = normalizeUrl(element.currentSrc || element.src || element.getAttribute && element.getAttribute("src") || "");
    var selectedText = "";
    try { selectedText = String(window.getSelection ? window.getSelection() : "").trim(); } catch (_) {}
    return {
      href: href,
      src: src,
      text: textForElement(link || media || element),
      selectedText: selectedText,
      tagName: element && element.tagName ? element.tagName.toLowerCase() : "",
      selector: selectorForElement(element),
      pageUrl: String(location.href || ""),
      pageTitle: String(document.title || "")
    };
  }

  function postElementContext(target) {
    try { LinkContextChannel.postMessage(JSON.stringify(contextForElement(target))); } catch (_) {}
  }

  function postLinkContext(href, text) {
    try {
      LinkContextChannel.postMessage(JSON.stringify({
        href: normalizeUrl(href),
        src: "",
        text: text || "",
        selectedText: "",
        tagName: "a",
        selector: "",
        pageUrl: String(location.href || ""),
        pageTitle: String(document.title || "")
      }));
    } catch (_) {}
  }

  function postMediaData(url, ct, cl) {
    try { MediaSnifferDataChannel.postMessage(JSON.stringify({url: String(url), contentType: ct || "", contentLength: cl || ""})); } catch (_) {}
  }

  // HLS/DASH content-type list used by the disguised playlist detector.
  function isHlsContentType(ct) {
    if (!ct) return false;
    var c = String(ct).toLowerCase();
    return c.indexOf('mpegurl') >= 0 ||
      c === 'application/vnd.apple.mpegurl' ||
      c === 'application/x-mpegurl' ||
      c === 'application/dash+xml';
  }

  // True when Content-Type is real media / playlist (not every response).
  // Intentionally skips application/octet-stream to avoid bridge floods.
  function isMediaContentType(ct) {
    if (!ct) return false;
    var c = String(ct).toLowerCase();
    if (c.indexOf('video/') === 0 || c.indexOf('audio/') === 0) return true;
    return isHlsContentType(c);
  }

  // URL looks like downloadable media by extension (or disguised playlist path).
  var _mediaUrlRe = /\.(mp4|m3u8|webm|mkv|avi|flv|mov|ts|mp3|wav|aac|ogg|m4a|flac|mpd|f4m|smil)([?#]|$)/i;
  function isMediaLikeUrl(url) {
    if (!url) return false;
    if (_mediaUrlRe.test(String(url))) return true;
    return hasPlaylistPathHint(url);
  }

  // Check if a URL path looks like a playlist path that might disguise an
  // HLS playlist under a non-.m3u8 extension (e.g. /hls/.../index.jpg).
  function hasPlaylistPathHint(url) {
    if (!url) return false;
    var path = "/";
    try { path = new URL(url).pathname.toLowerCase(); } catch (_) {}
    return path.indexOf('/hls/') >= 0 ||
      path.indexOf('/master') >= 0 ||
      path.indexOf('/playlist') >= 0 ||
      path.indexOf('/manifest') >= 0 ||
      path.indexOf('/dash/') >= 0;
  }

  // Detect and capture a disguised HLS/DASH playlist body.  When a response
  // body starts with #EXTM3U but the URL does not end in .m3u8, the CDN is
  // hiding the playlist behind a non-standard extension.  We capture the body
  // (for HlsPlaylistChannel) and re-post the URL with the correct content-type
  // so the Dart sniffer classifies it as a playlist, not an image/other.
  function captureDisguisedPlaylist(url, body) {
    if (!body || !url) return;
    var trimmed = body.replace(/^\s+/, "");
    if (trimmed.indexOf('#EXTM3U') !== 0) return;
    var u = String(url);
    try {
      HlsPlaylistChannel.postMessage(JSON.stringify({url: u, body: body}));
      MediaSnifferDataChannel.postMessage(JSON.stringify({
        url: u,
        contentType: 'application/vnd.apple.mpegurl',
        contentLength: ''
      }));
    } catch(_) {}
  }

  function postMediaElementSrc(element) {
    if (!element || !element.currentSrc) return;
    var url = element.currentSrc;
    // MediaSource blob URLs (e.g. blob:https://example.com/uuid) are created
    // by MSE-based players (HLS.js, etc.) and are NOT real network URLs.
    // They point to an in-memory streaming buffer inside the WebView and
    // cannot be downloaded via HTTP. Skip them so they don't enter the
    // sniffer and crash the downloader with "No host specified in URI".
    if (url.indexOf('blob:') === 0) return;
    var tag = element.tagName ? element.tagName.toLowerCase() : "";
    var ct = (tag === 'audio') ? 'audio/mpeg' : 'video/mp4';
    postMediaData(url, ct, "");
  }

  function shouldScanText(url, ct, cl) {
    // Only scan responses that are plaintext-like. Binary blobs (audio, video,
    // image, wasm, font, octet-stream) waste CPU on a regex that can never
    // match inside them.  Previously, responses with no content-type were
    // scanned optimistically — that caused the WebView's JS thread to block
    // on regex-matching large analytics responses for every fetch/XHR on
    // busy pages (Google search, etc.).  Only scan when the content-type
    // is explicitly text-like.
    if (cl && parseInt(cl) > 500000) return false;
    if (!ct) return false; // no content-type → skip (was: return true)
    var base = ct.split(';')[0].toLowerCase().trim();
    // Allow: javascript, json, xml, html, plain text
    if (base === 'application/javascript' ||
        base === 'text/javascript' ||
        base === 'application/json' ||
        base === 'text/json' ||
        base === 'application/xml' ||
        base === 'text/xml' ||
        base === 'text/html' ||
        base === 'text/plain') {
      return true;
    }
    // Block: anything binary
    if (base.indexOf('audio/') === 0 ||
        base.indexOf('video/') === 0 ||
        base.indexOf('image/') === 0 ||
        base.indexOf('font/') === 0 ||
        base === 'application/octet-stream' ||
        base === 'application/wasm') {
      return false;
    }
    // Default: skip unknown binary-ish types
    return false;
  }

  // Media-page heuristic: only scan response body text when the PAGE URL
  // suggests it hosts video/media content. On normal websites (docs, search,
  // social feeds) the response body scan is skipped entirely, avoiding the
  // expensive response.clone().text() + regex pass for every fetch/XHR.
  function _isMediaPage() {
    var h = location.href.toLowerCase();
    return h.indexOf('/watch') >= 0 ||
      h.indexOf('/video') >= 0 ||
      h.indexOf('/embed') >= 0 ||
      h.indexOf('/play') >= 0 ||
      h.indexOf('/live') >= 0 ||
      h.indexOf('/vod') >= 0 ||
      h.indexOf('/stream') >= 0 ||
      h.indexOf('/tv/') >= 0 ||
      h.indexOf('/episode') >= 0 ||
      h.indexOf('/series') >= 0 ||
      h.indexOf('/movie') >= 0 ||
      h.indexOf('/clip') >= 0 ||
      h.indexOf('/detail') >= 0 ||
      // Known video/porn hosts (common media pages)
      h.indexOf('youtube.com') >= 0 ||
      h.indexOf('pornhub.com') >= 0 ||
      h.indexOf('xvideos.com') >= 0 ||
      h.indexOf('xhamster.com') >= 0 ||
      h.indexOf('xnxx.com') >= 0 ||
      h.indexOf('redtube.com') >= 0 ||
      h.indexOf('youporn.com') >= 0 ||
      h.indexOf('tube8.com') >= 0 ||
      h.indexOf('spankbang.com') >= 0 ||
      h.indexOf('eporner.com') >= 0 ||
      h.indexOf('missav') >= 0 ||
      h.indexOf('beeg') >= 0;
  }
  var _mediaPage = _isMediaPage();

  // Cap inline-script scans so multi-MB SPA bundles do not freeze WebView JS.
  var _AURORA_MAX_SCRIPT_SCAN_CHARS = 250000;
  var _AURORA_MAX_INLINE_SCRIPTS = 40;
  function scanTextForUrls(text) {
    if (!text) return;
    // Truncate huge blobs before regex — exec on multi-MB strings is costly.
    if (text.length > _AURORA_MAX_SCRIPT_SCAN_CHARS) {
      text = text.slice(0, _AURORA_MAX_SCRIPT_SCAN_CHARS);
    }
    // Greedy match (+ not +?) so URLs like
    //   https://cdn.beeg24.org/.../video_1080p.mp4/index-v1-a1.m3u8?token=...
    // are captured fully (ending in .m3u8) rather than truncated at the
    // first .mp4 in the path.
    var urlRegex = /((?:(?:https?:)?\/\/|\/)[^\s"'`<>]+\.(?:mp4|m3u8|webm|mkv|avi|flv|mov|ts|mp3|wav|aac|ogg|m4a|flac|mpd|f4m|smil)(?:[^\s"'`<>]*))/gi;
    var matches;
    var count = 0;
    while ((matches = urlRegex.exec(text)) !== null && count < 100) {
      var u = matches[1];
      if (u) {
        // Skip URLs containing JavaScript template literal placeholders (${...}).
        // These are unresolved templates captured from <script> body text before
        // the page's JS evaluates them. They'd always fail at download time.
        if (u.indexOf('${') !== -1) continue;
        u = u.replace(/\\/g, '');
        try {
          var resolved = new URL(u, document.baseURI).href;
          postUrl(resolved);
          count++;
        } catch(_) {}
      }
    }
  }

  function postIframeSrc(url) {
    try { IframeSrcChannel.postMessage(String(url)); } catch (_) {}
  }

  function scanMedia(root) {
    try {
      var nodes = (root || document).querySelectorAll("a[href], video, audio, source[src], img[src], iframe[src], script");
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        if (node.tagName.toLowerCase() === 'script') {
          if (node.textContent) scanTextForUrls(node.textContent);
        } else if (node.tagName.toLowerCase() === 'iframe') {
          var iframeSrc = node.src || "";
          if (iframeSrc) {
            postUrl(iframeSrc);
            postIframeSrc(iframeSrc);
          }
        } else {
          var url = node.href || node.src || (node.currentSrc || "");
          if (url) postUrl(url);
        }
      }
    } catch (_) {}
  }

  // --- Re-installation gating via version counter ---
  if (window.__auroraGuardVersion > 0) return;

  // --- Style Injection ---
  try {
    var style = document.createElement('style');
    style.id = 'aurora-touch-callout-style';
    if (!document.getElementById('aurora-touch-callout-style')) {
      style.textContent = 'a, img, video, audio, [href], [src] { -webkit-touch-callout: none !important; -webkit-user-select: none !important; }';
      (document.head || document.documentElement).appendChild(style);
    }
  } catch(_) {}

  // --- popup blocking, invisible redirects, play-time ad-nav suppress ---
  // Sites like MissAV wire "play" to both video.play() and a cross-origin ad
  // redirect. When replace-site-player intercepts play(), we arm a short
  // suppress window so the ad navigation cannot steal the tab while Aurora
  // opens its player.
  //
  // Escape paths we harden here (in addition to Dart shouldOverride):
  // - target=_blank / _new (often loads in-tab when multi-window is off)
  // - synthetic a.click() / form.submit() stamped with a recent gesture
  // - window.location = non-string (URL objects)
  // - same-origin hops during play-ad suppress (ad intermediate pages)
  // - meta-refresh injected after first paint
  // - window.open with empty URL then later navigation (still cancelled)
  var _auroraLastUserGestureAt = 0;
  var _auroraLastPointerTarget = null;
  function markAuroraUserGesture(e) {
    _auroraLastUserGestureAt = Date.now();
    try { _auroraLastPointerTarget = e && e.target ? e.target : null; } catch(_) {
      _auroraLastPointerTarget = null;
    }
  }
  try {
    ['pointerdown', 'mousedown', 'touchstart', 'keydown'].forEach(function(evt) {
      window.addEventListener(evt, markAuroraUserGesture, {capture: true, passive: true});
    });
  } catch(_) {}
  function hasAuroraUserGesture() {
    try {
      if (navigator.userActivation && navigator.userActivation.isActive) return true;
    } catch(_) {}
    return Date.now() - _auroraLastUserGestureAt < 900;
  }
  function resolveAuroraUrl(url) {
    try { return new URL(String(url), document.baseURI).href; } catch(_) {}
    return String(url || '');
  }
  function isPlayAdNavSuppressed() {
    return Date.now() < (window.__auroraSuppressAdNavUntil || 0);
  }
  function armPlayAdNavSuppress(ms) {
    var dur = typeof ms === 'number' ? ms : 3000;
    window.__auroraSuppressAdNavUntil = Date.now() + dur;
  }
  function popupBlockingOn() {
    return window.__auroraPopupBlockingEnabled !== false || isPlayAdNavSuppressed();
  }
  function invisibleRedirectBlockingOn() {
    return window.__auroraInvisibleRedirectBlockingEnabled !== false ||
      isPlayAdNavSuppressed();
  }
  // Dart sets this before intentional loads (address bar / "Current tab").
  // Shape: true | '*' | {url, until} | string url
  // Wildcard stays active until `until` so HTTP redirect chains pass.
  function consumeAllowNextCrossOriginNav(url) {
    try {
      var g = window.__auroraAllowNextCrossOriginNav;
      if (!g) return false;
      if (typeof g === 'object' && g.until && Date.now() > g.until) {
        window.__auroraAllowNextCrossOriginNav = null;
        return false;
      }
      var target = resolveAuroraUrl(url);
      if (g === true || g === '*') return true;
      var allowed = typeof g === 'string' ? g : (g && g.url);
      if (!allowed) return false;
      if (allowed === '*') return true;
      if (target === allowed ||
          (target && allowed && target.indexOf(allowed) === 0)) {
        return true;
      }
      // Same host as allowed URL (path hop after user confirm).
      try {
        var a = new URL(allowed, document.baseURI);
        var t = new URL(target, document.baseURI);
        if (a.host && a.host === t.host) return true;
      } catch(_) {}
    } catch(_) {}
    return false;
  }
  function isHashOnlyNav(url) {
    try {
      var resolved = new URL(String(url), document.baseURI);
      var cur = new URL(location.href);
      return resolved.origin === cur.origin &&
        resolved.pathname === cur.pathname &&
        resolved.search === cur.search;
    } catch(_) { return false; }
  }
  // Hosts that should almost never be treated as silent ad redirects
  // (OAuth / IdP / payment). Skip intercept unless play-ad suppress is armed.
  var _AURORA_AUTH_HOST_SUFFIXES = [
    'accounts.google.com', 'accounts.youtube.com',
    'login.microsoftonline.com', 'login.live.com', 'account.live.com',
    'appleid.apple.com', 'id.apple.com',
    'www.facebook.com', 'm.facebook.com', 'facebook.com',
    'github.com', 'gitlab.com',
    'twitter.com', 'x.com', 'api.twitter.com',
    'auth0.com', 'okta.com',
    'paypal.com', 'checkout.stripe.com', 'js.stripe.com',
    'login.yahoo.com', 'api.amazon.com', 'amazon.com'
  ];
  function hostMatchesSuffix(host, suffix) {
    return host === suffix || host.endsWith('.' + suffix);
  }
  function isLikelyAuthOrPaymentUrl(url) {
    try {
      var u = new URL(String(url), document.baseURI);
      var h = (u.host || '').toLowerCase();
      for (var i = 0; i < _AURORA_AUTH_HOST_SUFFIXES.length; i++) {
        if (hostMatchesSuffix(h, _AURORA_AUTH_HOST_SUFFIXES[i])) return true;
      }
      var path = (u.pathname || '').toLowerCase();
      if (/\/(oauth2?|authorize|signin|sign-in|sign_in|login|sso|openid|saml|connect\/|checkout|pay)\b/.test(path)) {
        return true;
      }
    } catch(_) {}
    return false;
  }
  // App deep links (tg:, intent://, market://, mailto:, …) must leave the
  // WebView. Never treat them as silent-ad redirects or popups — Dart
  // shouldOverride / loadRequest hand them to ACTION_VIEW.
  function isExternalAppSchemeUrl(url) {
    try {
      var s = String(url || '').trim();
      if (!s || s.charAt(0) === '#' || /^\s*javascript:/i.test(s)) return false;
      var u;
      try { u = new URL(s, document.baseURI); } catch(_) {
        return /^(tg|telegram|intent|market|mailto|tel|sms|smsto|whatsapp|geo|magnet|fb|fb-messenger|instagram|twitter|x-twitter|spotify|vnd\.youtube|itms|itms-apps|googlegmail|ms-outlook|zoommtg|slack|discord|viber|line|weixin|alipays|paypal):/i.test(s);
      }
      var proto = (u.protocol || '').replace(':', '').toLowerCase();
      if (!proto) return false;
      return proto !== 'http' && proto !== 'https' && proto !== 'about' &&
        proto !== 'data' && proto !== 'blob' && proto !== 'javascript' &&
        proto !== 'file' && proto !== 'chrome' && proto !== 'chrome-error' &&
        proto !== 'chrome-native';
    } catch(_) { return false; }
  }
  function shouldInterceptRedirect(url) {
    if (url == null || url === '') return false;
    // Never block app schemes — Dart opens them outside the WebView.
    if (isExternalAppSchemeUrl(url)) return false;
    if (consumeAllowNextCrossOriginNav(url)) return false;
    if (isHashOnlyNav(url)) return false;
    // Always intercept during play-ad suppress (even if setting is off).
    var force = isPlayAdNavSuppressed();
    if (!force && window.__auroraInvisibleRedirectBlockingEnabled === false) {
      return false;
    }
    // User-initiated navigations (click / key / touch within gesture window)
    // must not be treated as silent ad redirects — that breaks OAuth, payments,
    // and intentional full-page hops. Scripted cross-origin still blocked below.
    if (!force && hasAuroraUserGesture()) return false;
    // Defense-in-depth: known auth/payment destinations (even without gesture).
    if (!force && isLikelyAuthOrPaymentUrl(url)) return false;
    try {
      var resolved = new URL(String(url), document.baseURI);
      // During play suppress, block same-origin hops too (ad intermediate
      // pages / token bounce) — hash-only already allowed above.
      if (force) return true;
      if (resolved.host === location.host &&
          resolved.protocol === location.protocol) {
        return false;
      }
      return true;
    } catch(_) {
      // Fail closed: unparseable absolute-looking targets still get blocked.
      return String(url).length > 0;
    }
  }
  function postInvisibleRedirect(url, method) {
    try {
      InvisibleRedirectChannel.postMessage(JSON.stringify({
        url: resolveAuroraUrl(url),
        rawUrl: String(url),
        method: String(method || 'unknown'),
        sourcePageUrl: location.href,
        userInitiated: hasAuroraUserGesture(),
        suppressedDuringPlay: isPlayAdNavSuppressed()
      }));
    } catch(_) {}
  }
  function postPopupBlocked(url, reason) {
    try {
      PopupBlockerChannel.postMessage(JSON.stringify({
        url: resolveAuroraUrl(url),
        userInitiated: hasAuroraUserGesture(),
        sourcePageUrl: location.href,
        reason: String(reason || 'popup')
      }));
    } catch(_) {}
  }
  function stopEventHard(ev) {
    try { ev.preventDefault(); } catch(_) {}
    try { ev.stopPropagation(); } catch(_) {}
    try { ev.stopImmediatePropagation(); } catch(_) {}
  }
  function isRealPointerOn(el) {
    try {
      if (!hasAuroraUserGesture() || !_auroraLastPointerTarget || !el) return false;
      return el === _auroraLastPointerTarget ||
        (el.contains && el.contains(_auroraLastPointerTarget));
    } catch(_) { return false; }
  }

  // --- popup blocking & window.open ---
  // When enabled, ALL window.open calls are cancelled and reported to Dart.
  // During play-ad suppress, same — even if gesture is active.
  var originalWindowOpen = window.open;
  window.open = function(url, name, specs) {
    // App schemes: always report to Dart (opens outside). Never invent a
    // blank popup handle ads could navigate later.
    if (url && isExternalAppSchemeUrl(url)) {
      postPopupBlocked(url, isPlayAdNavSuppressed() ? 'play-ad-suppress' : 'external-app');
      return null;
    }
    if (!popupBlockingOn()) {
      if (originalWindowOpen) {
        return originalWindowOpen.apply(this, arguments);
      }
      return null;
    }
    // Empty / about:blank opens are still cancelled so ads cannot create a
    // window handle then assign location later.
    if (url) {
      postPopupBlocked(url, isPlayAdNavSuppressed() ? 'play-ad-suppress' : 'popup');
    } else {
      postPopupBlocked('about:blank', isPlayAdNavSuppressed() ? 'play-ad-suppress' : 'popup-blank');
    }
    return null;
  };

  // --- location.href / window.location / replace / assign ---
  // Wrap only when descriptors are configurable. Preserve enumerability.
  // Failures under CSP/Trusted Types are swallowed so pages still load.
  // History API (pushState/replaceState) is intentionally NOT overridden.
  try {
    var _hrefDesc = Object.getOwnPropertyDescriptor(Location.prototype, 'href') ||
      Object.getOwnPropertyDescriptor(location, 'href');
    if (_hrefDesc && _hrefDesc.set && _hrefDesc.configurable !== false) {
      Object.defineProperty(Location.prototype, 'href', {
        get: function() { return _hrefDesc.get.call(this); },
        set: function(v) {
          var s = v == null ? '' : String(v);
          if (shouldInterceptRedirect(s)) { postInvisibleRedirect(s, 'href'); return; }
          return _hrefDesc.set.call(this, v);
        },
        configurable: true,
        enumerable: _hrefDesc.enumerable !== false
      });
    }
  } catch(_) {}
  try {
    var _winLocDesc = Object.getOwnPropertyDescriptor(Window.prototype, 'location');
    if (_winLocDesc && _winLocDesc.set && _winLocDesc.configurable !== false) {
      Object.defineProperty(Window.prototype, 'location', {
        get: function() { return _winLocDesc.get.call(this); },
        set: function(v) {
          var s = v == null ? '' : String(v);
          if (shouldInterceptRedirect(s)) {
            postInvisibleRedirect(s, 'window.location');
            return;
          }
          return _winLocDesc.set.call(this, v);
        },
        configurable: true,
        enumerable: _winLocDesc.enumerable !== false
      });
    }
  } catch(_) {}
  // document.location is often an accessor on Document.prototype.
  try {
    var _docLocDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'location');
    if (_docLocDesc && _docLocDesc.set && _docLocDesc.configurable !== false) {
      Object.defineProperty(Document.prototype, 'location', {
        get: function() { return _docLocDesc.get.call(this); },
        set: function(v) {
          var s = v == null ? '' : String(v);
          if (shouldInterceptRedirect(s)) {
            postInvisibleRedirect(s, 'document.location');
            return;
          }
          return _docLocDesc.set.call(this, v);
        },
        configurable: true,
        enumerable: _docLocDesc.enumerable !== false
      });
    }
  } catch(_) {}
  try {
    var _origReplace = Location.prototype.replace;
    Location.prototype.replace = function(url) {
      if (shouldInterceptRedirect(url)) { postInvisibleRedirect(url, 'replace'); return; }
      return _origReplace.call(this, url);
    };
  } catch(_) {}
  try {
    var _origAssign = Location.prototype.assign;
    Location.prototype.assign = function(url) {
      if (shouldInterceptRedirect(url)) { postInvisibleRedirect(url, 'assign'); return; }
      return _origAssign.call(this, url);
    };
  } catch(_) {}
  // Programmatic form.submit() bypasses the submit event in some engines.
  try {
    var _origFormSubmit = HTMLFormElement.prototype.submit;
    HTMLFormElement.prototype.submit = function() {
      try {
        var action = this.getAttribute('action') || this.action || '';
        if (action && shouldInterceptRedirect(action)) {
          postInvisibleRedirect(action, 'form-submit');
          return;
        }
      } catch(_) {}
      return _origFormSubmit.call(this);
    };
  } catch(_) {}

  function scanMetaRefresh() {
    if (!invisibleRedirectBlockingOn()) return;
    try {
      var metas = document.querySelectorAll(
        'meta[http-equiv="refresh" i], meta[http-equiv="Refresh"]'
      );
      // Fallback without case-insensitive attr selector for older WebViews.
      if (!metas || metas.length === 0) {
        metas = document.querySelectorAll('meta[http-equiv]');
      }
      for (var mi = 0; mi < metas.length; mi++) {
        var he = (metas[mi].getAttribute('http-equiv') || '');
        if (he.toLowerCase() !== 'refresh') continue;
        var content = metas[mi].getAttribute('content') || '';
        var match = content.match(/url\s*=\s*['"]?\s*([^'";\s]+)/i);
        if (match) {
          var murl = String(match[1]).replace(/&amp;/gi, '&');
          if (shouldInterceptRedirect(murl)) {
            try { metas[mi].remove(); } catch(_) {
              try { metas[mi].parentNode && metas[mi].parentNode.removeChild(metas[mi]); } catch(__) {}
            }
            postInvisibleRedirect(murl, 'meta-refresh');
          }
        }
      }
    } catch(_) {}
  }
  try {
    var _metaRefreshObserver = new MutationObserver(function() { scanMetaRefresh(); });
    var _startMetaObs = function() {
      try { scanMetaRefresh(); } catch(_) {}
      var root = document.documentElement || document.body;
      if (root) {
        _metaRefreshObserver.observe(root, {
          childList: true, subtree: true, attributes: true,
          attributeFilter: ['http-equiv', 'content']
        });
      } else {
        setTimeout(_startMetaObs, 50);
      }
    };
    _startMetaObs();
    try {
      document.addEventListener('DOMContentLoaded', scanMetaRefresh, true);
    } catch(_) {}
    // Late-injected meta refresh (ads after player load).
    try { setTimeout(scanMetaRefresh, 500); } catch(_) {}
    try { setTimeout(scanMetaRefresh, 2000); } catch(_) {}
  } catch(_) {}

  // Capture-phase click / submit shields (main frame + iframes when injected).
  try {
    document.addEventListener('click', function(ev) {
      try {
        if (ev.defaultPrevented) return;
        var t = ev.target;
        var a = t && t.closest ? t.closest('a[href], area[href]') : null;
        if (!a) return;
        var hrefAttr = a.getAttribute('href');
        if (hrefAttr == null) return;
        var href = String(hrefAttr).trim();
        if (!href || href.charAt(0) === '#' ||
            /^\s*javascript:/i.test(href)) {
          return;
        }
        var target = (a.getAttribute('target') || '').toLowerCase();
        var isBlank = target === '_blank' || target === '_new';

        // App deep links (tg:, mailto:, intent://, …): never popup-block.
        // For target=_blank preventDefault so the WebView doesn't invent a
        // dead tab; Dart still gets the URL via postPopupBlocked → external.
        if (isExternalAppSchemeUrl(href)) {
          if (isBlank) {
            stopEventHard(ev);
            postPopupBlocked(href, 'external-app');
          }
          // Non-blank: allow default → shouldOverride opens the app.
          return;
        }

        // New-window style links → popup blocker (WebView often loads in-tab).
        if (isBlank && popupBlockingOn()) {
          stopEventHard(ev);
          postPopupBlocked(
            href,
            isPlayAdNavSuppressed() ? 'play-ad-suppress' : 'target-blank'
          );
          return;
        }

        if (!shouldInterceptRedirect(href)) return;

        // Play-ad window: always cancel navigations that would leave the page.
        if (isPlayAdNavSuppressed()) {
          stopEventHard(ev);
          postInvisibleRedirect(href, 'play-click-link');
          return;
        }

        // Programmatic .click() / scripted activation without pointer on link.
        if (!isRealPointerOn(a)) {
          stopEventHard(ev);
          postInvisibleRedirect(href, 'synthetic-click');
          return;
        }

        // target=_top / _parent cross-origin: treat as redirect (not user tab).
        if ((target === '_top' || target === '_parent') &&
            invisibleRedirectBlockingOn()) {
          stopEventHard(ev);
          postInvisibleRedirect(href, 'target-' + target.replace('_', ''));
          return;
        }
      } catch(_) {}
    }, true);

    document.addEventListener('submit', function(ev) {
      try {
        if (!invisibleRedirectBlockingOn()) return;
        var form = ev.target;
        if (!form) return;
        var action = '';
        try {
          action = form.getAttribute('action') || form.action || '';
        } catch(_) { action = ''; }
        if (!action) return;
        if (shouldInterceptRedirect(action)) {
          stopEventHard(ev);
          postInvisibleRedirect(action, 'form-submit');
        }
      } catch(_) {}
    }, true);

    // Auxclick (middle-click) new-tab style open.
    document.addEventListener('auxclick', function(ev) {
      try {
        if (!popupBlockingOn()) return;
        if (ev.button !== 1) return;
        var t = ev.target;
        var a = t && t.closest ? t.closest('a[href]') : null;
        if (!a) return;
        var href = a.getAttribute('href') || '';
        if (!href || href.charAt(0) === '#') return;
        stopEventHard(ev);
        postPopupBlocked(href, 'auxclick');
      } catch(_) {}
    }, true);
  } catch(_) {}

  // --- long press and context menu ---
  var lastContextPostAt = 0;
  var suppressClickUntil = 0;
  var touchTimer = null;
  var touchTarget = null;
  var touchStartX = 0;
  var touchStartY = 0;
  var lastScrollAt = 0;

  window.addEventListener("scroll", function() {
    lastScrollAt = Date.now();
  }, { passive: true, capture: true });

  function hasTextSelection() {
    try {
      var sel = window.getSelection ? window.getSelection() : null;
      return !!(sel && sel.toString().trim().length > 0);
    } catch (_) {
      return false;
    }
  }

  function postLongPressContext(target) {
    // Text selections are handled by the native Android selection toolbar
    // (copy / paste / select-all / share) — don't show our custom menu.
    if (hasTextSelection()) return;
    if (Date.now() - lastContextPostAt < 400) return;
    lastContextPostAt = Date.now();
    suppressClickUntil = lastContextPostAt + 150;
    postElementContext(target);
  }

  function clearLongPressTimer() {
    if (touchTimer) {
      clearTimeout(touchTimer);
      touchTimer = null;
    }
  }

  document.addEventListener("contextmenu", function(event) {
    // For text selections, let the native Android selection toolbar
    // (copy / paste / select-all / share) appear instead of our custom menu.
    if (hasTextSelection()) return;
    try { event.preventDefault(); } catch (_) {}
    // Suppress context menu if the user recently scrolled — the Android
    // WebView can fire contextmenu when the user settles their finger
    // after a scroll, which used to trigger an unwanted context menu
    // up to ~1s later.  This also matches the JS touchstart guard
    // (but with a longer window to cover fling-stop touches).
    if (Date.now() - lastScrollAt < 800) return;
    if (Date.now() - lastContextPostAt < 1000) return;
    postLongPressContext(event.target);
  }, true);

  document.addEventListener("touchstart", function(event) {
    clearLongPressTimer();
    if (Date.now() - lastScrollAt < 500) return;
    if (!event.touches || event.touches.length !== 1) return;
    touchTarget = event.target;
    touchStartX = event.touches[0].clientX;
    touchStartY = event.touches[0].clientY;
    touchTimer = setTimeout(function() {
      clearLongPressTimer();
      postLongPressContext(touchTarget);
    }, 1200);
  }, true);

  document.addEventListener("touchmove", function(event) {
    if (!touchTimer || !event.touches || event.touches.length !== 1) return;
    var dx = Math.abs(event.touches[0].clientX - touchStartX);
    var dy = Math.abs(event.touches[0].clientY - touchStartY);
    if (dx > 10 || dy > 10) clearLongPressTimer();
  }, true);

  document.addEventListener("touchend", clearLongPressTimer, true);
  document.addEventListener("touchcancel", clearLongPressTimer, true);
  document.addEventListener("click", function(event) {
    if (window.__auroraElementPickerActive) return;
    if (Date.now() < suppressClickUntil) {
      try {
        event.preventDefault();
        event.stopImmediatePropagation();
      } catch (_) {}
    }
  }, true);

  // --- Fetch hook ---
  // Only bridge media-like URLs / content-types — posting every response
  // (analytics, CSS, JSON APIs) flooded Dart mid page-load.
  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function(input, init) {
      return originalFetch.apply(this, arguments).then(function(response) {
        if (response.url) {
          try {
            var ct = response.headers.get('content-type') || "";
            var cl = response.headers.get('content-length') || "";
            var mediaCt = isMediaContentType(ct);
            var mediaUrl = isMediaLikeUrl(response.url);
            if (mediaCt || mediaUrl) {
              postUrl(response.url);
            }
            if (mediaCt) postMediaData(response.url, ct, cl);
            // Only scan response body text on known media pages — on typical
            // websites (search, docs, social) the regex scan is pure overhead.
            if (_mediaPage && shouldScanText(response.url, ct, cl)) {
              response.clone().text().then(function(text) {
                scanTextForUrls(text);
              }).catch(function() {});
            }
            // Capture .m3u8 response bodies for HlsPlaylistChannel
            var _hlsUrl = response.url.toLowerCase();
            if (_hlsUrl.indexOf('.m3u8') >= 0) {
              response.clone().text().then(function(body) {
                try {
                  HlsPlaylistChannel.postMessage(JSON.stringify({url: response.url, body: body}));
                } catch(_) {}
              }).catch(function() {});
            } else if (hasPlaylistPathHint(response.url) || isHlsContentType(ct)) {
              // Disguised playlist: URL doesn't contain .m3u8 but path/content-type
              // hints suggest it could be an HLS playlist. Read the body and check.
              response.clone().text().then(function(body) {
                captureDisguisedPlaylist(response.url, body);
              }).catch(function() {});
            }
          } catch(_) {}
        }
        return response;
      }).catch(function(err) {
        var url = (typeof input === "string") ? input : (input && input.url) || "";
        if (url && isMediaLikeUrl(url)) postUrl(url);
        throw err;
      });
    };
  }

  // --- XHR hook ---
  var xhrOpen = XMLHttpRequest.prototype.open;
  var xhrSend = XMLHttpRequest.prototype.send;
  if (xhrOpen) {
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__auroraUrl = String(url || "");
      return xhrOpen.apply(this, arguments);
    };
  }
  if (xhrSend) {
    XMLHttpRequest.prototype.send = function() {
      var self = this;
      var url = self.__auroraUrl || "";
      // Gate pre-response postUrl the same way as fetch (media-like only).
      if (url && isMediaLikeUrl(url)) postUrl(url);
      self.addEventListener('loadend', function() {
        try {
          var finalUrl = self.responseURL || url;
          var ct = self.getResponseHeader('content-type') || "";
          var cl = self.getResponseHeader('content-length') || "";
          var mediaCt = isMediaContentType(ct);
          var mediaUrl = isMediaLikeUrl(finalUrl);
          // If we only learned media-ness from Content-Type, post now.
          if (mediaCt || mediaUrl) {
            postUrl(finalUrl);
          }
          if (mediaCt) postMediaData(finalUrl, ct, cl);
          // Only scan response body text on known media pages.
          if (_mediaPage && shouldScanText(finalUrl, ct, cl) && self.responseText) {
            scanTextForUrls(self.responseText);
          }
          // Capture .m3u8 response bodies for HlsPlaylistChannel
          var _hlsXhrUrl = String(finalUrl).toLowerCase();
          if (_hlsXhrUrl.indexOf('.m3u8') >= 0 && self.responseText) {
            try {
              HlsPlaylistChannel.postMessage(JSON.stringify({url: finalUrl, body: self.responseText}));
            } catch(_) {}
          } else if (self.responseText &&
              (hasPlaylistPathHint(finalUrl) || isHlsContentType(ct))) {
            // Disguised playlist: body exists and path/content-type suggests HLS.
            captureDisguisedPlaylist(finalUrl, self.responseText);
          }
        } catch(_) {}
      }, { once: true });
      return xhrSend.apply(this, arguments);
    };
  }

  // --- Element src descriptors ---
  try {
    var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        get: function() { return desc.get.call(this); },
        set: function(v) { postUrl(String(v)); return desc.set.call(this, v); },
        configurable: true
      });
    }
  } catch(_) {}

  try {
    var srcDesc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
    if (srcDesc) {
      Object.defineProperty(HTMLSourceElement.prototype, 'src', {
        get: function() { return srcDesc.get.call(this); },
        set: function(v) { postUrl(String(v)); return srcDesc.set.call(this, v); },
        configurable: true
      });
    }
  } catch(_) {}

  // --- setAttribute hook ---
  try {
    var origSetAttr = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function(name, value) {
      if ((name === 'src' || name === 'data-src') &&
          (this instanceof HTMLMediaElement || this instanceof HTMLSourceElement)) {
        postUrl(String(value));
      }
      return origSetAttr.apply(this, arguments);
    };
  } catch(_) {}

  // --- Media Element Event Listeners ---
  document.addEventListener('loadedmetadata', function(e) {
    if (e.target instanceof HTMLMediaElement) postMediaElementSrc(e.target);
  }, true);
  document.addEventListener('play', function(e) {
    if (e.target instanceof HTMLMediaElement) postMediaElementSrc(e.target);
  }, true);
  document.addEventListener('canplay', function(e) {
    if (e.target instanceof HTMLMediaElement) postMediaElementSrc(e.target);
  }, true);

  // --- IDM-style floating control + optional auto-replace ---
  // Default: site player works; Dart shows a floating play icon over the
  // largest visible <video>. When window.__auroraReplaceSitePlayer is true
  // (Settings → Auto-open Aurora on site play), intercept play() instead.
  if (!window.__auroraReplacePlayerHooked) {
    window.__auroraReplacePlayerHooked = true;
    if (typeof window.__auroraReplaceSitePlayer === 'undefined') {
      window.__auroraReplaceSitePlayer = false;
    }
    var _auroraOrigPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() {
      if (!window.__auroraReplaceSitePlayer) {
        try { scheduleVideoFloatReport(); } catch (_) {}
        return _auroraOrigPlay.apply(this, arguments);
      }
      try {
        // Arm before posting so any ad redirect that fires in the same
        // click handler (location.href / window.open) is cancelled.
        try { armPlayAdNavSuppress(3500); } catch (_) {}
        var src = '';
        try { src = this.currentSrc || this.src || ''; } catch (_) { src = ''; }
        var isVideo = false;
        try { isVideo = this instanceof HTMLVideoElement; } catch (_) { isVideo = true; }
        var currentTime = 0;
        try { currentTime = this.currentTime || 0; } catch (_) {}
        try { this.pause(); } catch (_) {}
        try { this.muted = true; } catch (_) {}
        try {
          if (this.removeAttribute) this.removeAttribute('autoplay');
        } catch (_) {}
        // Soft-hide the site player so it does not flash under Aurora.
        try {
          if (this.style && isVideo) {
            this.dataset.auroraReplaced = '1';
            this.style.opacity = '0.15';
          }
        } catch (_) {}
        var needsSniffed = !src ||
          src.indexOf('blob:') === 0 ||
          src.indexOf('data:') === 0 ||
          src.indexOf('mediasource:') === 0 ||
          src.indexOf('mse:') === 0;
        var payload = JSON.stringify({
          url: src || '',
          currentTime: currentTime,
          isVideo: !!isVideo,
          needsSniffed: !!needsSniffed
        });
        try {
          if (window.AuroraPlayChannel && AuroraPlayChannel.postMessage) {
            AuroraPlayChannel.postMessage(payload);
          } else if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('AuroraPlayChannel', payload);
          }
        } catch (_) {}
      } catch (_) {}
      return Promise.resolve();
    };

    // Capture-phase click shield: many ad players use a transparent overlay
    // <a href="ad"> or onclick that navigates away on the same tap as play.
    // When suppress is armed, stop those navigations before they start.
    try {
      document.addEventListener('click', function(ev) {
        if (!isPlayAdNavSuppressed()) return;
        try {
          var t = ev.target;
          var a = t && t.closest ? t.closest('a[href], area[href]') : null;
          if (a) {
            var href = a.getAttribute('href') || a.href || '';
            if (href && shouldInterceptRedirect(href)) {
              ev.preventDefault();
              ev.stopPropagation();
              try { ev.stopImmediatePropagation(); } catch (_) {}
              postInvisibleRedirect(href, 'play-click-link');
              return;
            }
          }
        } catch (_) {}
      }, true);
    } catch(_) {}
  }

  // --- Video float rect (IDM-style floating button positioning) ---
  // Reports the largest visible <video> bounding box so Flutter can park a
  // play control on the video. Throttled via rAF; skipped when auto-replace
  // is on (no floating control needed).
  var _videoFloatRaf = 0;
  var _lastVideoFloatKey = '';
  function postVideoFloat(payload) {
    try {
      var s = JSON.stringify(payload);
      if (window.VideoFloatChannel && VideoFloatChannel.postMessage) {
        VideoFloatChannel.postMessage(s);
      } else if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('VideoFloatChannel', s);
      }
    } catch (_) {}
  }
  function reportVideoFloat() {
    _videoFloatRaf = 0;
    if (window.__auroraReplaceSitePlayer) {
      if (_lastVideoFloatKey !== 'off') {
        _lastVideoFloatKey = 'off';
        postVideoFloat({ hasVideo: false });
      }
      return;
    }
    try {
      var vids = document.querySelectorAll('video');
      var best = null;
      var bestArea = 0;
      var vw = window.innerWidth || 0;
      var vh = window.innerHeight || 0;
      for (var i = 0; i < vids.length; i++) {
        var v = vids[i];
        if (!v || v.dataset && v.dataset.auroraReplaced === '1') continue;
        var r = v.getBoundingClientRect();
        if (!r || r.width < 80 || r.height < 45) continue;
        // Must intersect viewport a bit.
        var ix = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
        var iy = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
        if (ix < 40 || iy < 30) continue;
        var area = r.width * r.height;
        if (area > bestArea) {
          bestArea = area;
          best = r;
        }
      }
      if (!best) {
        if (_lastVideoFloatKey !== 'none') {
          _lastVideoFloatKey = 'none';
          postVideoFloat({ hasVideo: false });
        }
        return;
      }
      var key = [
        Math.round(best.left),
        Math.round(best.top),
        Math.round(best.width),
        Math.round(best.height)
      ].join(',');
      if (key === _lastVideoFloatKey) return;
      _lastVideoFloatKey = key;
      postVideoFloat({
        hasVideo: true,
        left: best.left,
        top: best.top,
        width: best.width,
        height: best.height
      });
    } catch (_) {}
  }
  function scheduleVideoFloatReport() {
    if (_videoFloatRaf) return;
    try {
      _videoFloatRaf = requestAnimationFrame(reportVideoFloat);
    } catch (_) {
      reportVideoFloat();
    }
  }
  if (!window.__auroraVideoFloatHooked) {
    window.__auroraVideoFloatHooked = true;
    try {
      window.addEventListener('scroll', scheduleVideoFloatReport, { passive: true, capture: true });
      window.addEventListener('resize', scheduleVideoFloatReport, { passive: true });
      document.addEventListener('loadedmetadata', function(e) {
        if (e.target instanceof HTMLMediaElement) scheduleVideoFloatReport();
      }, true);
      document.addEventListener('play', function(e) {
        if (e.target instanceof HTMLMediaElement) scheduleVideoFloatReport();
      }, true);
      // Periodic light poll — covers SPA layout shifts without MutationObserver storms.
      setInterval(scheduleVideoFloatReport, 1500);
      scheduleVideoFloatReport();
    } catch (_) {}
  }

  // --- Media Error Detection ---
  // When a <video> or <audio> element fails to load its source (e.g. 404 from
  // a dead CDN link), display a plain overlay so the user knows the video is
  // no longer available, instead of staring at a blank player.
  //
  // Uses a flag to install once. The flag resets on full page navigation (new
  // document context), so the listener is correctly re-established for each
  // fresh page load. On force re-inject (same document), the flag prevents
  // duplicate listeners.
  (function() {
    if (window.__auroraMediaErrorActive) return;
    window.__auroraMediaErrorActive = true;

    document.addEventListener('error', function(e) {
      var target = e.target;
      if (!target || !(target instanceof HTMLMediaElement)) return;

      var error = target.error;
      if (!error) return;

      var message = '';
      switch (error.code) {
        case MediaError.MEDIA_ERR_NETWORK:
          message = '视频源无法加载（服务器连接失败）\nVideo source is unavailable (server error or removed)';
          break;
        case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED:
          message = '视频格式不支持\nVideo format is not supported';
          break;
        case MediaError.MEDIA_ERR_DECODE:
          message = '视频解码失败\nVideo decode error';
          break;
        default:
          return; // MEDIA_ERR_ABORTED (user-aborted) or unknown — skip
      }

      // Find the closest reasonable container to place the overlay in.
      var container = target.closest(
        '#bofang_box, .play, .detail_right_tab, [class*="video"], [class*="player"], [id*="video"], [id*="player"]'
      );
      if (!container) container = target.parentElement;
      if (!container) container = target;

      // Prevent duplicate overlays (e.g. if multiple error events fire).
      if (container.querySelector('.aurora-media-error-overlay')) return;

      var overlay = document.createElement('div');
      overlay.className = 'aurora-media-error-overlay';
      overlay.style.cssText =
        'position:absolute;top:0;left:0;width:100%;height:100%;' +
        'display:flex;flex-direction:column;align-items:center;justify-content:center;' +
        'background:rgba(0,0,0,0.78);color:#e0e0e0;font-size:14px;text-align:center;' +
        'padding:20px;z-index:9999;pointer-events:none;' +
        'font-family:"PingFang SC","Microsoft YaHei",sans-serif;' +
        'white-space:pre-line;line-height:1.6;';

      overlay.textContent = message;

      // Ensure the container is positioned so absolute overlay works.
      var cs = window.getComputedStyle(container);
      if (cs.position === 'static') container.style.position = 'relative';

      container.appendChild(overlay);
    }, true);
  })();

  // --- createObjectURL hook ---
  // MediaSource blob URLs (e.g. blob:https://example.com/uuid) are NOT
  // real network URLs — they point to an in-memory streaming buffer inside
  // the WebView and cannot be downloaded via HTTP. The fetch/XHR
  // interceptor and PerformanceObserver already capture the real source
  // URLs (.m3u8 playlists, .ts segments, .mp4 chunks) that the player
  // fetches before feeding them to the MediaSource. Posting the blob URL
  // here only adds noise that crashes the downloader, so the hook is a
  // passthrough and no longer posts to the sniffer.
  try {
    var origCreateObjectURL = URL.createObjectURL;
    if (origCreateObjectURL) {
      URL.createObjectURL = function(obj) {
        return origCreateObjectURL.apply(this, arguments);
      };
    }
  } catch(_) {}

  // --- PerformanceObserver ---
  if (!window.__auroraPerformanceObserverActive) {
    window.__auroraPerformanceObserverActive = true;
    try {
      // .ts is excluded so HLS fragments do not flood the sniffer.
      var mediaRe = /\.(mp4|m3u8|webm|mkv|avi|flv|mov|mp3|wav|aac|ogg|m4a|flac|mpd|f4m|smil)([?#].*)?$/i;
      // CRITICAL: previously matched ALL fetch/xmlhttprequest entries, which
      // flooded the platform channel with hundreds of analytics/tracking
      // XHRs on busy pages (Google search, etc.), saturating the WebView's
      // JS thread and the Dart event loop → scroll freeze + ANR crash.
      // Now only matches media URLs by extension or media-element init.
      function isMediaEntry(entry) {
        if (mediaRe.test(entry.name)) return true;
        return entry.initiatorType === 'media';
      }
      // No replay of past entries — `buffered: true` caused the observer
      // to re-fire every past resource, flooding the channel on page load.
      var perfObserver = new PerformanceObserver(function(list) {
        var entries = list.getEntries();
        for (var i = 0; i < entries.length; i++) {
          if (isMediaEntry(entries[i])) postUrl(entries[i].name);
        }
      });
      perfObserver.observe({ type: 'resource' });
    } catch(_) {}
  }

  // --- Initial Media / HTML Scan ---
  if (!window.__auroraHtmlScanned) {
    window.__auroraHtmlScanned = true;
    scanMedia(document);
    // Scan inline <script> tag text only — video platforms embed media URLs
    // in JS blobs, not general HTML. Scanning the full innerHTML with a greedy
    // regex on a large SPA page causes main-thread jank. The MutationObserver
    // and DOM-based scanMedia() already handle <video>, <audio>, <source> and
    // <a> elements so the broad innerHTML scan is fully redundant for those.
    try {
      var scripts = document.querySelectorAll('script:not([src])');
      var scanned = 0;
      for (var si = 0; si < scripts.length && scanned < _AURORA_MAX_INLINE_SCRIPTS; si++) {
        var body = scripts[si].textContent;
        if (!body) continue;
        // Skip oversized inline scripts entirely (after global char cap in scanner).
        if (body.length > _AURORA_MAX_SCRIPT_SCAN_CHARS) continue;
        scanTextForUrls(body);
        scanned++;
      }
    } catch(_) {}
    setTimeout(function() { try { scanMedia(document); } catch(_) {} }, 500);
    // 1500ms delayed scan removed — the MutationObserver and 500ms scan
    // already catch dynamic content added after initial paint.
  }

  // --- MutationObserver (debounced via requestAnimationFrame) ---
  // Batching mutations on the next animation frame prevents expensive
  // scanMedia + querySelectorAll calls from blocking the JS thread during
  // bursts of DOM mutations (SPA rendering, ad insertion, lazy-loading).
  if (!window.__auroraObserverActive) {
    window.__auroraObserverActive = true;
    var _moNodes = [];
    var _moScheduled = false;
    function _flushMutations() {
      _moScheduled = false;
      var nodes = _moNodes;
      _moNodes = [];
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        if (node && node.querySelectorAll) scanMedia(node);
      }
    }
    var observer = new MutationObserver(function(records) {
      for (var i = 0; i < records.length; i++) {
        var record = records[i];
        if (record.type === 'childList') {
          for (var j = 0; j < record.addedNodes.length; j++) {
            var node = record.addedNodes[j];
            if (node && node.querySelectorAll) {
              _moNodes.push(node);
            }
          }
        } else if (record.type === 'attributes') {
          var node = record.target;
          if (node) {
            var tag = node.tagName ? node.tagName.toLowerCase() : "";
            if (tag === 'video' || tag === 'audio' || tag === 'source' || tag === 'iframe' || tag === 'a') {
              var url = node.href || node.src || (node.currentSrc || "");
              if (url) postUrl(url);
            }
          }
        }
      }
      if (!_moScheduled && _moNodes.length > 0) {
        _moScheduled = true;
        requestAnimationFrame(_flushMutations);
      }
    });
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'href', 'data-src']
    });
  }

  // --- Text selection bridge ---
  if (!window.__auroraSelectionActive) {
    window.__auroraSelectionActive = true;
    var __auroraLastSelection = '';
    var __auroraLastSelectionAt = 0;
    document.addEventListener('selectionchange', function() {
      try {
        var sel = window.getSelection ? window.getSelection() : null;
        if (!sel || sel.rangeCount === 0) return;
        var text = String(sel.toString() || '').trim();
        if (text.length < 2) return;
        if (text.length > 400) text = text.slice(0, 400);
        var now = Date.now();
        if (text === __auroraLastSelection && (now - __auroraLastSelectionAt) < 350) return;
        __auroraLastSelection = text;
        __auroraLastSelectionAt = now;
        if (window.TextSelectionChannel && TextSelectionChannel.postMessage) {
          TextSelectionChannel.postMessage(text);
        }
      } catch (_) {}
    });
  }


  // --- Interactive Element Picker ---
  (function() {
    // Inject picker animation keyframes once
    (function() {
      var animId = 'aurora-picker-anim';
      if (!document.getElementById(animId)) {
        var s = document.createElement('style');
        s.id = animId;
        s.textContent = '@keyframes aurora-picker-dash {\n' +
          '  0% { border-color: #88C0D0; box-shadow: 0 0 4px rgba(136,192,208,0.4); }\n' +
          '  50% { border-color: #8FBCBB; box-shadow: 0 0 10px rgba(136,192,208,0.8); }\n' +
          '  100% { border-color: #88C0D0; box-shadow: 0 0 4px rgba(136,192,208,0.4); }\n' +
          '}\n';
        (document.head || document.documentElement).appendChild(s);
      }
    })();

    var activeBorder = null;
    var confirmOverlay = null;
    var selectedElement = null;

    function cleanup() {
      if (activeBorder) {
        activeBorder.remove();
        activeBorder = null;
      }
      if (confirmOverlay) {
        confirmOverlay.remove();
        confirmOverlay = null;
      }
      selectedElement = null;
    }

    document.addEventListener("click", function(event) {
      if (!window.__auroraElementPickerActive) return;

      // Prevent normal clicks/navigation/actions
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      var target = event.target;
      if (!target) return;

      // Skip clicks on our own buttons/overlays
      if (target.closest('.aurora-picker-overlay') || target.closest('.aurora-picker-border')) {
        return;
      }

      cleanup();
      selectedElement = target;

      var rect = target.getBoundingClientRect();
      var scrollLeft = window.pageXOffset || document.documentElement.scrollLeft;
      var scrollTop = window.pageYOffset || document.documentElement.scrollTop;

      // Draw teal neon animated dashed outline
      activeBorder = document.createElement('div');
      activeBorder.className = 'aurora-picker-border';
      activeBorder.style.position = 'absolute';
      activeBorder.style.left = (rect.left + scrollLeft - 2) + 'px';
      activeBorder.style.top = (rect.top + scrollTop - 2) + 'px';
      activeBorder.style.width = (rect.width + 4) + 'px';
      activeBorder.style.height = (rect.height + 4) + 'px';
      activeBorder.style.border = '2px dashed #88C0D0';
      activeBorder.style.animation = 'aurora-picker-dash 1.5s ease-in-out infinite';
      activeBorder.style.pointerEvents = 'none';
      activeBorder.style.zIndex = '2147483647';
      activeBorder.style.opacity = '0';
      activeBorder.style.transition = 'opacity 0.16s ease-out';
      document.body.appendChild(activeBorder);

      // Create overlay confirmation panel with Tick and Cross
      confirmOverlay = document.createElement('div');
      confirmOverlay.className = 'aurora-picker-overlay';
      confirmOverlay.style.position = 'absolute';
      
      var viewportWidth = window.innerWidth || document.documentElement.clientWidth;
      var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
      var overlayTop = (rect.top + scrollTop - 48);
      if (overlayTop < scrollTop) overlayTop = (rect.bottom + scrollTop + 8);
      if (overlayTop + 48 > scrollTop + viewportHeight) {
        overlayTop = scrollTop + viewportHeight - 56;
      }
      if (overlayTop < scrollTop) overlayTop = scrollTop + 4;
      confirmOverlay.style.top = overlayTop + 'px';
      var overlayLeft = Math.max(8, rect.left + scrollLeft);
      if (overlayLeft + 100 > viewportWidth) overlayLeft = Math.max(8, viewportWidth - 116);
      confirmOverlay.style.left = overlayLeft + 'px';
      confirmOverlay.style.zIndex = '2147483647';
      confirmOverlay.style.background = '#1A242F';
      confirmOverlay.style.border = '2px solid #3A4D62';
      confirmOverlay.style.borderRadius = '6px';
      confirmOverlay.style.padding = '4px 8px';
      confirmOverlay.style.display = 'flex';
      confirmOverlay.style.gap = '12px';
      confirmOverlay.style.boxShadow = '0 4px 12px rgba(0,0,0,0.6)';
      confirmOverlay.style.opacity = '0';
      confirmOverlay.style.transform = 'scale(0.92)';
      confirmOverlay.style.transition = 'opacity 0.16s ease-out, transform 0.16s ease-out';

      var tickBtn = document.createElement('button');
      tickBtn.innerText = '✔';
      tickBtn.style.color = '#2ecc71';
      tickBtn.style.background = 'transparent';
      tickBtn.style.border = 'none';
      tickBtn.style.fontSize = '20px';
      tickBtn.style.fontWeight = 'bold';
      tickBtn.style.cursor = 'pointer';
      tickBtn.style.padding = '2px 8px';

      var crossBtn = document.createElement('button');
      crossBtn.innerText = '✖';
      crossBtn.style.color = '#e74c3c';
      crossBtn.style.background = 'transparent';
      crossBtn.style.border = 'none';
      crossBtn.style.fontSize = '20px';
      crossBtn.style.fontWeight = 'bold';
      crossBtn.style.cursor = 'pointer';
      crossBtn.style.padding = '2px 8px';

      tickBtn.onclick = function() {
        if (!selectedElement) return;
        var info = contextForElement(selectedElement);
        try {
          ElementPickerChannel.postMessage(JSON.stringify({
            src: info.src || "",
            selector: info.selector || "",
            host: location.host
          }));
        } catch (_) {}
        window.__auroraElementPickerActive = false;
        cleanup();
      };

      crossBtn.onclick = function() {
        cleanup();
      };

      confirmOverlay.appendChild(tickBtn);
      confirmOverlay.appendChild(crossBtn);
      document.body.appendChild(confirmOverlay);
      requestAnimationFrame(function() {
        requestAnimationFrame(function() {
          if (activeBorder) activeBorder.style.opacity = '1';
          if (confirmOverlay) {
            confirmOverlay.style.opacity = '1';
            confirmOverlay.style.transform = 'scale(1)';
          }
        });
      });
    }, true);
  })();

  // --- Media Poster Harvest ---
  // Walks <video>/<audio> elements and reports each element's source together
  // with the poster image the page already shows for it. Dart stores the poster
  // on SniffedMedia.thumbnailUrl and paints it as the capture-row thumbnail, so
  // the sheet shows the same frame the user was looking at instead of a generic
  // type icon. Cosmetic only — a missing or broken poster just falls back.
  (function() {
    if (window.__auroraPosterHarvestActive) return;
    window.__auroraPosterHarvestActive = true;

    // src|poster pairs already sent. Bounded like the URL cache above so a
    // long-lived SPA cannot grow it without limit.
    var _sentPairs = {};
    var _sentPairsCount = 0;

    function posterFor(el) {
      try {
        // 1. The element's own poster attribute — the authoritative frame.
        var own = el.getAttribute && el.getAttribute('poster');
        if (own) return normalizeUrl(own);

        // 2. A poster-ish <img> inside the same player container. Many players
        //    (JW, Video.js, Plyr) paint the still as a sibling <img> rather
        //    than using the poster attribute. Walk at most 3 levels up so we
        //    stay inside the player and never reach page chrome.
        var node = el.parentElement;
        for (var depth = 0; node && depth < 3; depth++) {
          var img = node.querySelector('img[src]');
          if (img) {
            var w = img.naturalWidth || img.width || 0;
            // Ignore control-strip icons and tracking pixels.
            if (w >= 120) return normalizeUrl(img.getAttribute('src'));
          }
          node = node.parentElement;
        }
      } catch (_) {}
      return '';
    }

    function srcFor(el) {
      try {
        // currentSrc is the resolved choice across a <source> set.
        if (el.currentSrc) return normalizeUrl(el.currentSrc);
        if (el.src) return normalizeUrl(el.src);
        var source = el.querySelector && el.querySelector('source[src]');
        if (source) return normalizeUrl(source.getAttribute('src'));
      } catch (_) {}
      return '';
    }

    function scan() {
      try {
        var els = document.querySelectorAll('video, audio');
        for (var i = 0; i < els.length; i++) {
          var src = srcFor(els[i]);
          if (!src) continue;
          var poster = posterFor(els[i]);
          // No poster and nothing else to add — the network sniffer already has
          // this URL, so stay quiet rather than spend a bridge hop.
          if (!poster) continue;

          var key = src + '|' + poster;
          if (_sentPairs[key]) continue;
          _sentPairs[key] = true;
          if (++_sentPairsCount > 200) { _sentPairs = {}; _sentPairsCount = 0; }

          try {
            MediaMetaChannel.postMessage(
              JSON.stringify({ src: src, poster: poster })
            );
          } catch (_) {}
        }
      } catch (_) {}
    }

    // Players swap in the real source well after DOMContentLoaded, so sample a
    // few times rather than once. The observer catches later SPA route changes.
    scan();
    setTimeout(scan, 800);
    setTimeout(scan, 2500);

    try {
      var pending = null;
      var observer = new MutationObserver(function() {
        // Coalesce — player init can fire hundreds of mutations in a burst.
        if (pending) return;
        pending = setTimeout(function() { pending = null; scan(); }, 500);
      });
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['src', 'poster'],
      });
    } catch (_) {}
  })();

  // --- Page Meta Extraction ---
  // Extracts OG meta tags, JSON-LD structured data, and the document title,
  // then posts them via PageMetaChannel (consumed in sniffer_screen.dart to
  // generate meaningful download filenames instead of raw WebView titles).
  //
  // This channel was registered but NEVER populated — without it every download
  // gets named from the raw <title> tag containing site branding like
  // "SULASOK - BEST FREE PINAY PORN..." or "Search results for ...".
  (function() {
    if (window.__auroraPageMetaActive) return;
    window.__auroraPageMetaActive = true;

    function extractPageMeta() {
      try {
        var meta = {
          title: '',
          ogTitle: '',
          twitterTitle: '',
          h1Title: '',
          ogVideoWidth: '',
          ogVideoHeight: '',
          ogImage: '',
          ldName: '',
          codeLabel: '',
        };

        meta.title = document.title || '';

        // OG + Twitter meta tags (property="" or name="" forms).
        // MissAV (and many hosts) truncate <title> (~55 chars) while
        // og:title / twitter:title keep the full descriptive name.
        var metas = document.querySelectorAll(
          'meta[property^="og:"], meta[name^="og:"], ' +
            'meta[name^="twitter:"], meta[property^="twitter:"]'
        );
        for (var i = 0; i < metas.length; i++) {
          var prop =
            metas[i].getAttribute('property') ||
            metas[i].getAttribute('name') ||
            '';
          var content = metas[i].getAttribute('content') || '';
          if (prop === 'og:title') meta.ogTitle = content;
          else if (prop === 'twitter:title') meta.twitterTitle = content;
          else if (prop === 'og:video:width') meta.ogVideoWidth = content;
          else if (prop === 'og:video:height') meta.ogVideoHeight = content;
          // Page artwork — the capture sheet's fallback row thumbnail when a
          // media element has no poster of its own. og:image wins over
          // twitter:image; neither overwrites an already-resolved value.
          else if (prop === 'og:image' && !meta.ogImage) {
            meta.ogImage = normalizeUrl(content);
          } else if (prop === 'twitter:image' && !meta.ogImage) {
            meta.ogImage = normalizeUrl(content);
          }
        }

        // Primary page heading — on MissAV this matches the full og:title
        // and is more reliable than the truncated document.title.
        try {
          var h1 = document.querySelector('h1');
          if (h1) {
            var h1Text = (h1.textContent || '').replace(/\s+/g, ' ').trim();
            if (h1Text.length >= 4) meta.h1Title = h1Text;
          }
        } catch (_) {}

        // Optional product code line (e.g. "Code: LULU-172-UNCENSORED-LEAK")
        try {
          var bodyText = document.body ? document.body.innerText || '' : '';
          var codeMatch = bodyText.match(/Code:\s*([A-Za-z0-9][A-Za-z0-9._\-]{2,40})/i);
          if (codeMatch) meta.codeLabel = codeMatch[1].trim();
        } catch (_) {}

        // JSON-LD structured data
        var ldScripts = document.querySelectorAll(
          'script[type="application/ld+json"]'
        );
        for (var j = 0; j < ldScripts.length; j++) {
          try {
            var ld = JSON.parse(ldScripts[j].textContent || '{}');
            // Walk common LD shapes: direct, @graph, @id containers
            var items = ld['@graph'] || [ld];
            for (var k = 0; k < items.length; k++) {
              var item = items[k];
              if (item && item.name && item.name !== meta.ogTitle) {
                meta.ldName = item.name;
                break;
              }
            }
            if (!meta.ogTitle && ld.headline) {
              meta.ogTitle = ld.headline;
            }
          } catch (_) {}
        }

        return meta;
      } catch (_) {
        return { title: document.title || '' };
      }
    }

    function postMeta() {
      var m = extractPageMeta();
      try {
        PageMetaChannel.postMessage(JSON.stringify(m));
      } catch (_) {}
    }

    // Immediate post for SSR pages + delayed for SPAs / client-rendered content.
    // MutationObserver on <title> catches SPA route changes.
    postMeta();
    setTimeout(postMeta, 600);
    setTimeout(postMeta, 1800);

    // Observe <title> for client-side navigation (SPA apps like Next.js)
    try {
      var titleEl = document.querySelector('head title');
      if (titleEl) {
        var titleObserver = new MutationObserver(function () {
          postMeta();
        });
        titleObserver.observe(titleEl, {
          childList: true,
          subtree: true,
          characterData: true,
        });
      }
    } catch (_) {}

    // Also observe meta tags (og:title, og:description, etc.) for SPAs that
    // update them via JavaScript after the initial render. Without this,
    // pageMeta.title stays as the stale placeholder title like "Pinayum Player"
    // even though the real og:title was set client-side.
    try {
      var metaObserver = new MutationObserver(function () {
        postMeta();
      });
      metaObserver.observe(document.head, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['content'],
      });
    } catch (_) {}
  })();

  window.__auroraGuardVersion = (window.__auroraGuardVersion || 0) + 1;
})();