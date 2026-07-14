(function() {
  // --- Aurora Channel Shim for flutter_inappwebview ---
  // Maps old webview_flutter API: ChannelName.postMessage(data)
  // To new flutter_inappwebview API: window.flutter_inappwebview.callHandler(name, data)
  if (!window.__auroraChannelShim) {
    window.__auroraChannelShim = true;
    var __auroraChannels = ['MediaSnifferChannel','MediaSniffer','MediaSnifferDataChannel','LinkContextChannel','AdBlockerChannel','IframeSrcChannel','PopupBlockerChannel','ElementPickerChannel','MediaMetaChannel','PageMetaChannel','TextSelectionChannel','HlsPlaylistChannel','InvisibleRedirectChannel'];
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
      var nodes = root.querySelectorAll('video, audio, source, a[href], img[src], iframe, script:not([src])');
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

  // --- Stealth: anti-automation detection ---
  // Hides WebView automation markers that Cloudflare and similar WAFs
  // check via JavaScript challenges.  Only runs once per document.
  if (!window.__auroraStealthActive) {
    window.__auroraStealthActive = true;
    try {
      // 1. navigator.webdriver → false (prevents automation detection).
      //    Standard Chrome returns false.  Android WebView with debugging
      //    enabled returns true — false is the correct non-automated value.
      Object.defineProperty(navigator, 'webdriver', {
        get: function() { return false; },
        configurable: false
      });
    } catch(_) {}
    try {
      // 2. Remove chrome.runtime (ChromeDriver / automation artifact).
      //    Some WAFs check for chrome.runtime to detect controlled browsers.
      if (window.chrome) {
        try {
          chrome.runtime = void 0;
          Object.defineProperty(chrome, 'runtime', {
            get: function() { return void 0; },
            set: function(_) {},
            configurable: false
          });
        } catch(_e) { chrome.runtime = void 0; }
        delete chrome.app;
        delete chrome.csi;
        delete chrome.loadTimes;
      }
    } catch(_) {}
    try {
      // 3. navigator.languages — WebView typically exposes only the system
      //    language.  Real Chrome returns a fallback chain like
      //    ['en-US', 'en', 'zh-CN', 'zh'].  A single language can
      //    fingerprint WebView-based scrapers.
      Object.defineProperty(navigator, 'languages', {
        get: function() { return ['en-US', 'en']; },
        configurable: false
      });
    } catch(_) {}
    try {
      // 4. navigator.hardwareConcurrency — Override to a realistic mobile value.
      Object.defineProperty(navigator, 'hardwareConcurrency', {
        get: function() { return 4; },
        configurable: false
      });
    } catch(_) {}
    try {
      // 5. navigator.deviceMemory — Override to a realistic mobile value.
      Object.defineProperty(navigator, 'deviceMemory', {
        get: function() { return 4; },
        configurable: false
      });
    } catch(_) {}
    try {
      // 6. Remove ChromeDriver / CDP artifacts on the document object.
      //    Bot detectors enumerate own property names looking for
      //    $cdc_* or $chrome_* keys injected by ChromeDriver/DevTools.
      var _keys = Object.getOwnPropertyNames(document);
      for (var _ki = 0; _ki < _keys.length; _ki++) {
        if (_keys[_ki].indexOf('$cdc_') === 0 || _keys[_ki].indexOf('$chrome_') === 0) {
          try { delete document[_keys[_ki]]; } catch(_) {}
        }
      }
    } catch(_) {}
  }

  // --- Re-installation gating via version counter ---
  if (window.__auroraGuardVersion > 0) return;

  // --- Style Injection ---
  try {
    var style = document.createElement('style');
    style.id = 'aurora-touch-callout-style';
    if (!document.getElementById('aurora-touch-callout-style')) {
      style.textContent = 'a, img, video, audio, [href], [src] { -webkit-touch-callout: none !important; }';
      (document.head || document.documentElement).appendChild(style);
    }
  } catch(_) {}

  // --- popup blocking & window.open ---
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
  var originalWindowOpen = window.open;
  window.open = function(url, name, specs) {
    if (window.__auroraPopupBlockingEnabled === false) {
      if (originalWindowOpen) {
        return originalWindowOpen.apply(this, arguments);
      }
    } else {
      if (url) {
        try {
          PopupBlockerChannel.postMessage(JSON.stringify({
            url: resolveAuroraUrl(url),
            userInitiated: hasAuroraUserGesture(),
            sourcePageUrl: location.href
          }));
        } catch (_) {}
      }
      return null;
    }
  };

  // --- invisible redirect blocking (location.href, replace, assign, meta-refresh) ---
  // Cross-origin silent redirects (ad scripts using location.href, window.location,
  // location.replace, location.assign, or <meta http-equiv="refresh">) are intercepted.
  // Same-origin redirects (site navigation, hash changes, same-domain buttons) pass through.
  // The redirect is CANCELLED in JS, the URL is posted to InvisibleRedirectChannel,
  // and the Dart side shows a snackbar: Block / Open here / Open in new tab.
  var _invisibleRedirectGate = false;
  function shouldInterceptRedirect(url) {
    if (window.__auroraInvisibleRedirectBlockingEnabled === false) return false;
    if (_invisibleRedirectGate) { _invisibleRedirectGate = false; return false; }
    if (!url) return false;
    try {
      var resolved = new URL(String(url), document.baseURI);
      // Same-origin → allow (hash changes, same-domain buttons, site nav)
      if (resolved.host === location.host && resolved.protocol === location.protocol) return false;
      return true; // Cross-origin → intercept
    } catch(_) { return false; }
  }

  function postInvisibleRedirect(url, method) {
    try {
      InvisibleRedirectChannel.postMessage(JSON.stringify({
        url: resolveAuroraUrl(url),
        rawUrl: String(url),
        method: String(method || "unknown"),
        sourcePageUrl: location.href,
        userInitiated: hasAuroraUserGesture()
      }));
    } catch(_) {}
  }

  // 1. Location.prototype.href setter (catches location.href=, location='url')
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

  // 2. window.location setter (catches window.location='url', document.location='url')
  try {
    var _winLocDesc = Object.getOwnPropertyDescriptor(Window.prototype, 'location');
    if (_winLocDesc && _winLocDesc.set) {
      Object.defineProperty(Window.prototype, 'location', {
        get: function() { return _winLocDesc.get.call(this); },
        set: function(v) {
          if (typeof v === 'string' && shouldInterceptRedirect(v)) { postInvisibleRedirect(v, 'window.location'); return; }
          return _winLocDesc.set.call(this, v);
        },
        configurable: true
      });
    }
  } catch(_) {}

  // 3. Location.prototype.replace (catches location.replace(url))
  try {
    var _origReplace = Location.prototype.replace;
    Location.prototype.replace = function(url) {
      if (shouldInterceptRedirect(url)) { postInvisibleRedirect(url, 'replace'); return; }
      return _origReplace.call(this, url);
    };
  } catch(_) {}

  // 4. Location.prototype.assign (catches location.assign(url))
  try {
    var _origAssign = Location.prototype.assign;
    Location.prototype.assign = function(url) {
      if (shouldInterceptRedirect(url)) { postInvisibleRedirect(url, 'assign'); return; }
      return _origAssign.call(this, url);
    };
  } catch(_) {}

  // 5. Meta-refresh scan (catches <meta http-equiv="refresh" content="0;url=...">)
  function scanMetaRefresh() {
    if (window.__auroraInvisibleRedirectBlockingEnabled === false) return;
    try {
      var metas = document.querySelectorAll('meta[http-equiv="refresh"]');
      for (var mi = 0; mi < metas.length; mi++) {
        var content = metas[mi].getAttribute('content') || '';
        var match = content.match(/url\s*=\s*['"]?\s*([^\s'"&]+)/i);
        if (match) {
          var url = String(match[1]);
          if (shouldInterceptRedirect(url)) {
            metas[mi].remove();
            postInvisibleRedirect(url, 'meta-refresh');
          }
        }
      }
    } catch(_) {}
  }

  // 6. MutationObserver for dynamically added meta-refresh tags
  //    (the main observer below also fires for 'http-equiv' and 'content' attribute changes)
  function metaRefreshObserverCallback(mutations) {
    for (var mi = 0; mi < mutations.length; mi++) {
      var m = mutations[mi];
      if (m.type === 'attributes' || m.type === 'childList') {
        scanMetaRefresh();
        break;
      }
    }
  }
  // Use a lightweight observer dedicated to meta-refresh so we don't pollute
  // the main observer's heavy buffer with attribute changes on <meta>.
  var _metaRefreshObserver = null;
  try {
    _metaRefreshObserver = new MutationObserver(metaRefreshObserverCallback);
    // Wait for document body to be available
    var _startMetaObs = function() {
      if (document.body) {
        _metaRefreshObserver.observe(document.documentElement || document.body, {
          childList: true,
          subtree: true,
          attributes: true,
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
  var lastScrollAt = 0;

  window.addEventListener("scroll", function() {
    lastScrollAt = Date.now();
  }, { passive: true, capture: true });

  function shouldInterceptContext(target) {
    if (!target) return false;
    var element = target.nodeType === 1 ? target : target.parentElement;
    if (!element) return false;
    var link = element.closest ? element.closest("a[href]") : null;
    if (link) return true;
    var media = element.closest ? element.closest("img[src],video,audio,source[src]") : null;
    if (media) return true;
    return false;
  }

  function hasSelectedContextText() {
    try {
      return String(window.getSelection ? window.getSelection() : "").trim().length > 0;
    } catch (_) {
      return false;
    }
  }

  function postLongPressContext(target) {
    if (Date.now() - lastContextPostAt < 400) return;
    var ctx = contextForElement(target);
    if (!ctx.href && !ctx.src && !ctx.selectedText) return;
    lastContextPostAt = Date.now();
    suppressClickUntil = lastContextPostAt + 150;
    postElementContext(target);
  }

  document.addEventListener("contextmenu", function(event) {
    if (!shouldInterceptContext(event.target) && !hasSelectedContextText()) {
      return; // Blank-space long-press: no Aurora context action.
    }
    try { event.preventDefault(); } catch (_) {}
    if (Date.now() - lastScrollAt < 800) return;
    if (Date.now() - lastContextPostAt < 1000) return;
    postLongPressContext(event.target);
  }, true);

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
  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function(input, init) {
      return originalFetch.apply(this, arguments).then(function(response) {
        if (response.url) {
          postUrl(response.url);
          try {
            var ct = response.headers.get('content-type') || "";
            var cl = response.headers.get('content-length') || "";
            if (ct) postMediaData(response.url, ct, cl);
            var _hlsUrl = response.url.toLowerCase();
            var isHls = _hlsUrl.indexOf('.m3u8') >= 0 || hasPlaylistPathHint(response.url) || isHlsContentType(ct);
            var isText = shouldScanText(response.url, ct, cl);
            if (isHls || isText) {
              response.clone().text().then(function(text) {
                if (isText) {
                  scanTextForUrls(text);
                }
                if (isHls) {
                  if (_hlsUrl.indexOf('.m3u8') >= 0) {
                    try {
                      HlsPlaylistChannel.postMessage(JSON.stringify({url: response.url, body: text}));
                    } catch(_) {}
                  } else {
                    captureDisguisedPlaylist(response.url, text);
                  }
                }
              }).catch(function() {});
            }
          } catch(_) {}
        }
        return response;
      }).catch(function(err) {
        var url = (typeof input === "string") ? input : (input && input.url) || "";
        if (url) postUrl(url); throw err;
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
      if (url) postUrl(url);
      self.addEventListener('loadend', function() {
        try {
          var ct = self.getResponseHeader('content-type') || "";
          var cl = self.getResponseHeader('content-length') || "";
          if (ct) postMediaData(self.responseURL || url, ct, cl);
          if (shouldScanText(self.responseURL || url, ct, cl) && self.responseText) {
            scanTextForUrls(self.responseText);
          }
          // Capture .m3u8 response bodies for HlsPlaylistChannel
          var _hlsXhrUrl = (self.responseURL || url).toLowerCase();
          if (_hlsXhrUrl.indexOf('.m3u8') >= 0 && self.responseText) {
            try {
              HlsPlaylistChannel.postMessage(JSON.stringify({url: self.responseURL || url, body: self.responseText}));
            } catch(_) {}
          } else if (self.responseText && hasPlaylistPathHint(self.responseURL || url)) {
            // Disguised playlist: body exists and path suggests HLS.
            captureDisguisedPlaylist(self.responseURL || url, self.responseText);
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
      // Now only matches media URLs by extension, media-element init, or
      // playlist path hints (/hls/, /master/, /playlist/, /manifest/, /dash/).
      function isMediaEntry(entry) {
        if (mediaRe.test(entry.name)) return true;
        if (entry.initiatorType === 'media') return true;
        // Path hints for disguised playlists (e.g. .../hls/.../index.jpg)
        try {
          var _path = new URL(entry.name).pathname.toLowerCase();
          if (_path.indexOf('/hls/') >= 0 ||
              _path.indexOf('/master') >= 0 ||
              _path.indexOf('/playlist') >= 0 ||
              _path.indexOf('/manifest') >= 0 ||
              _path.indexOf('/dash/') >= 0) {
            return true;
          }
        } catch(_) {}
        return false;
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
    try { scanMetaRefresh(); } catch(_) {}
    setTimeout(function() { try { scanMedia(document); } catch(_) {} }, 500);
    setTimeout(function() { try { scanMedia(document); } catch(_) {} }, 1500);
  }

  // --- MutationObserver ---
  if (!window.__auroraObserverActive) {
    window.__auroraObserverActive = true;
    var pendingNodes = [];
    var scanTimeout = null;
    function flushPendingNodes() {
      var nodes = pendingNodes;
      pendingNodes = [];
      scanTimeout = null;
      for (var i = 0; i < nodes.length; i++) {
        scanMedia(nodes[i]);
      }
    }
    var observer = new MutationObserver(function(records) {
      for (var i = 0; i < records.length; i++) {
        var record = records[i];
        if (record.type === 'childList') {
          for (var j = 0; j < record.addedNodes.length; j++) {
            var node = record.addedNodes[j];
            if (node && node.querySelectorAll) {
              if (pendingNodes.indexOf(node) === -1) {
                if (pendingNodes.length >= 200) pendingNodes.shift();
                pendingNodes.push(node);
              }
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
      if (pendingNodes.length > 0 && !scanTimeout) {
        scanTimeout = setTimeout(flushPendingNodes, 100);
      }
    });
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'href', 'data-src']
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
    }, true);
  })();

  window.__auroraGuardVersion = (window.__auroraGuardVersion || 0) + 1;
})();
