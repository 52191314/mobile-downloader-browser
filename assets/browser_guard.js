(function() {
  // --- Aurora Channel Shim for flutter_inappwebview ---
  // Maps old webview_flutter API: ChannelName.postMessage(data)
  // To new flutter_inappwebview API: window.flutter_inappwebview.callHandler(name, data)
  if (!window.__auroraChannelShim) {
    window.__auroraChannelShim = true;
    var __auroraChannels = ['MediaSnifferChannel','MediaSniffer','MediaSnifferDataChannel','LinkContextChannel','AdBlockerChannel','IframeSrcChannel','PopupBlockerChannel','ElementPickerChannel','MediaMetaChannel','PageMetaChannel','TextSelectionChannel','HlsPlaylistChannel','NavigationSwipeChannel','AuroraPlayChannel','InvisibleRedirectChannel'];
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

  function scanTextForUrls(text) {
    if (!text) return;
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
  var _auroraLastUserGestureAt = 0;
  function markAuroraUserGesture() {
    _auroraLastUserGestureAt = Date.now();
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

  // --- popup blocking & window.open ---
  // When enabled, ALL window.open calls are cancelled and reported to Dart
  // (dialog). During play-ad suppress, same — even if gesture is active.
  var originalWindowOpen = window.open;
  window.open = function(url, name, specs) {
    if (window.__auroraPopupBlockingEnabled === false && !isPlayAdNavSuppressed()) {
      if (originalWindowOpen) {
        return originalWindowOpen.apply(this, arguments);
      }
      return null;
    }
    if (url) {
      try {
        PopupBlockerChannel.postMessage(JSON.stringify({
          url: resolveAuroraUrl(url),
          userInitiated: hasAuroraUserGesture(),
          sourcePageUrl: location.href,
          reason: isPlayAdNavSuppressed() ? 'play-ad-suppress' : 'popup'
        }));
      } catch (_) {}
    }
    return null;
  };

  // --- invisible redirect blocking (location.href / replace / assign / meta) ---
  var _invisibleRedirectGate = false;
  function shouldInterceptRedirect(url) {
    if (_invisibleRedirectGate) { _invisibleRedirectGate = false; return false; }
    if (!url) return false;
    // Always intercept during play-ad suppress (even if setting is off momentarily).
    var force = isPlayAdNavSuppressed();
    if (!force && window.__auroraInvisibleRedirectBlockingEnabled === false) return false;
    try {
      var resolved = new URL(String(url), document.baseURI);
      if (resolved.host === location.host && resolved.protocol === location.protocol) {
        return false; // same-origin always allowed
      }
      return true;
    } catch(_) { return false; }
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
  try {
    var _hrefDesc = Object.getOwnPropertyDescriptor(Location.prototype, 'href');
    if (_hrefDesc && _hrefDesc.set) {
      Object.defineProperty(Location.prototype, 'href', {
        get: function() { return _hrefDesc.get.call(this); },
        set: function(v) {
          if (shouldInterceptRedirect(v)) { postInvisibleRedirect(v, 'href'); return; }
          return _hrefDesc.set.call(this, v);
        },
        configurable: true,
        enumerable: _hrefDesc.enumerable
      });
    }
  } catch(_) {}
  try {
    var _winLocDesc = Object.getOwnPropertyDescriptor(Window.prototype, 'location');
    if (_winLocDesc && _winLocDesc.set) {
      Object.defineProperty(Window.prototype, 'location', {
        get: function() { return _winLocDesc.get.call(this); },
        set: function(v) {
          if (typeof v === 'string' && shouldInterceptRedirect(v)) {
            postInvisibleRedirect(v, 'window.location');
            return;
          }
          return _winLocDesc.set.call(this, v);
        },
        configurable: true
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
  function scanMetaRefresh() {
    if (window.__auroraInvisibleRedirectBlockingEnabled === false &&
        !isPlayAdNavSuppressed()) return;
    try {
      var metas = document.querySelectorAll('meta[http-equiv="refresh"]');
      for (var mi = 0; mi < metas.length; mi++) {
        var content = metas[mi].getAttribute('content') || '';
        var match = content.match(/url\s*=\s*['"]?\s*([^\s'"&]+)/i);
        if (match) {
          var murl = String(match[1]);
          if (shouldInterceptRedirect(murl)) {
            metas[mi].remove();
            postInvisibleRedirect(murl, 'meta-refresh');
          }
        }
      }
    } catch(_) {}
  }
  try {
    var _metaRefreshObserver = new MutationObserver(function() { scanMetaRefresh(); });
    var _startMetaObs = function() {
      if (document.body) {
        _metaRefreshObserver.observe(document.documentElement || document.body, {
          childList: true, subtree: true, attributes: true,
          attributeFilter: ['http-equiv', 'content']
        });
      } else {
        setTimeout(_startMetaObs, 200);
      }
    };
    _startMetaObs();
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

  // --- UC-style: replace site player with Aurora ---
  // When window.__auroraReplaceSitePlayer is true, intercept play() so the
  // site's own <video>/<audio> does not start; Dart opens AuroraVideoPlayer
  // with cookies/headers from the capturing tab.
  if (!window.__auroraReplacePlayerHooked) {
    window.__auroraReplacePlayerHooked = true;
    if (typeof window.__auroraReplaceSitePlayer === 'undefined') {
      window.__auroraReplaceSitePlayer = true;
    }
    var _auroraOrigPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() {
      if (!window.__auroraReplaceSitePlayer) {
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
      for (var si = 0; si < scripts.length; si++) {
        if (scripts[si].textContent) scanTextForUrls(scripts[si].textContent);
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