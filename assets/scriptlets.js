// Copyright (c) 2026 Aurora Downloader Authors. All rights reserved.
// Proprietary & Confidential — In-house Scriptlet Engine for content protection & ad defusal.

(function() {
  'use strict';

  if (window.__auroraScriptletsLoaded) return;
  window.__auroraScriptletsLoaded = true;

  var _registry = Object.create(null);
  var _invoked = Object.create(null);

  // --- Internal Utility Helpers ---

  function makeRandomToken() {
    return Math.random().toString(36).substring(2, 11);
  }

  function compileRegex(raw) {
    if (!raw || typeof raw !== 'string') return new RegExp('.?');
    if (raw.charCodeAt(0) === 47 /* '/' */ && raw.lastIndexOf('/') > 0) {
      var lastIdx = raw.lastIndexOf('/');
      var pattern = raw.slice(1, lastIdx);
      var flags = raw.slice(lastIdx + 1);
      try {
        return new RegExp(pattern, flags);
      } catch (_) {}
    }
    var escaped = raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(escaped);
  }

  function resolvePath(root, pathStr) {
    if (!root || !pathStr) return null;
    var segments = pathStr.split('.');
    var current = root;
    for (var i = 0; i < segments.length - 1; i++) {
      var seg = segments[i];
      if (current[seg] == null) {
        current[seg] = {};
      }
      current = current[seg];
    }
    return {
      parent: current,
      prop: segments[segments.length - 1]
    };
  }

  function parseConstantValue(val) {
    if (val === 'true') return true;
    if (val === 'false') return false;
    if (val === 'null') return null;
    if (val === 'undefined') return undefined;
    if (val === 'noopFunc' || val === 'noopCallback') return function() {};
    if (val === 'trueFunc') return function() { return true; };
    if (val === 'falseFunc') return function() { return false; };
    if (val === 'emptyObj') return {};
    if (val === 'emptyArr') return [];
    if (!isNaN(Number(val)) && val.trim() !== '') return Number(val);
    return val;
  }

  // --- Public Interface ---

  var __auroraScriptlets = {
    invoke: function(name, args) {
      if (!name) return;
      var callSig = name + (args && args.length ? '::' + args.join(';') : '');
      if (_invoked[callSig]) return;
      _invoked[callSig] = true;

      var handler = _registry[name];
      if (typeof handler === 'function') {
        try {
          handler(args || []);
        } catch (_) {}
      }
    }
  };

  window.__auroraScriptlets = __auroraScriptlets;

  // --- 1. abort-on-property-read ---
  _registry['abort-on-property-read'] = function(args) {
    if (!args || !args[0]) return;
    var target = resolvePath(window, args[0]);
    if (!target) return;

    var token = makeRandomToken();
    var storedValue = target.parent[target.prop];

    Object.defineProperty(target.parent, target.prop, {
      get: function() {
        throw new ReferenceError(token);
      },
      set: function(v) {
        storedValue = v;
      },
      configurable: true
    });

    var prevErr = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.indexOf(token) !== -1) return true;
      if (typeof prevErr === 'function') return prevErr.apply(window, arguments);
      return false;
    };
  };

  // --- 2. abort-on-property-write ---
  _registry['abort-on-property-write'] = function(args) {
    if (!args || !args[0]) return;
    var target = resolvePath(window, args[0]);
    if (!target) return;

    var token = makeRandomToken();
    Object.defineProperty(target.parent, target.prop, {
      get: function() {
        return undefined;
      },
      set: function() {
        throw new ReferenceError(token);
      },
      configurable: true
    });

    var prevErr = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.indexOf(token) !== -1) return true;
      if (typeof prevErr === 'function') return prevErr.apply(window, arguments);
      return false;
    };
  };

  // --- 3. abort-current-inline-script ---
  _registry['abort-current-inline-script'] = function(args) {
    if (!args || args.length < 2) return;
    var pathStr = args[0];
    var matcher = compileRegex(args[1]);
    var target = resolvePath(window, pathStr);
    if (!target) return;

    var original = target.parent[target.prop];
    if (typeof original !== 'function') return;
    var token = makeRandomToken();

    target.parent[target.prop] = function() {
      try {
        var current = document.currentScript;
        if (current && current.textContent && matcher.test(current.textContent)) {
          throw new ReferenceError(token);
        }
      } catch (e) {
        if (e instanceof ReferenceError && e.message === token) {
          throw e;
        }
      }
      return original.apply(this, arguments);
    };

    var prevErr = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.indexOf(token) !== -1) return true;
      if (typeof prevErr === 'function') return prevErr.apply(window, arguments);
      return false;
    };
  };

  // --- 4. set-constant ---
  _registry['set-constant'] = function(args) {
    if (!args || !args[0]) return;
    var target = resolvePath(window, args[0]);
    if (!target) return;

    var constantVal = args.length >= 2 ? parseConstantValue(args[1]) : true;
    Object.defineProperty(target.parent, target.prop, {
      get: function() {
        return constantVal;
      },
      set: function() {},
      configurable: true
    });
  };

  // --- 5. prevent-addEventListener ---
  _registry['prevent-addEventListener'] = function(args) {
    if (!args || !args[0]) return;
    var eventMatcher = compileRegex(args[0]);
    var handlerMatcher = args.length >= 2 ? compileRegex(args[1]) : null;

    var origAdd = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(evtType, listener, options) {
      if (eventMatcher.test(evtType)) {
        if (handlerMatcher && listener) {
          var handlerBody = String(listener);
          if (!handlerMatcher.test(handlerBody)) {
            return origAdd.call(this, evtType, listener, options);
          }
        }
        return;
      }
      return origAdd.call(this, evtType, listener, options);
    };
  };

  // --- 6. noeval ---
  _registry['noeval'] = function() {
    var token = makeRandomToken();
    window.eval = function() {
      throw new ReferenceError(token);
    };
    window.Function = function() {
      throw new ReferenceError(token);
    };
    var prevErr = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.indexOf(token) !== -1) return true;
      if (typeof prevErr === 'function') return prevErr.apply(window, arguments);
      return false;
    };
  };

  // --- 7. no-fetch-if & 19. prevent-fetch ---
  var blockFetchHandler = function(args) {
    if (!args || !args[0]) return;
    var matcher = compileRegex(args[0]);
    var origFetch = window.fetch;
    if (typeof origFetch !== 'function') return;

    window.fetch = function(input, init) {
      var reqUrl = typeof input === 'string' ? input : (input && input.url ? input.url : '');
      if (reqUrl && matcher.test(reqUrl)) {
        return Promise.reject(new TypeError('AdShield intercepted request'));
      }
      return origFetch.apply(this, arguments);
    };
  };
  _registry['no-fetch-if'] = blockFetchHandler;
  _registry['prevent-fetch'] = blockFetchHandler;

  // --- 8. no-xhr-if ---
  _registry['no-xhr-if'] = function(args) {
    if (!args || !args[0]) return;
    var matcher = compileRegex(args[0]);
    var origOpen = XMLHttpRequest.prototype.open;

    XMLHttpRequest.prototype.open = function(method, url) {
      if (url && matcher.test(String(url))) {
        return;
      }
      return origOpen.apply(this, arguments);
    };
  };

  // --- 9. no-window-open-if ---
  _registry['no-window-open-if'] = function(args) {
    if (!args || !args[0]) return;
    var matcher = compileRegex(args[0]);
    var origWinOpen = window.open;

    window.open = function(url) {
      if (url && matcher.test(String(url))) {
        return null;
      }
      return origWinOpen.apply(this, arguments);
    };
  };

  // --- 10. set-timeout-defuser ---
  _registry['set-timeout-defuser'] = function(args) {
    if (!args || !args[0]) return;
    var callbackMatcher = compileRegex(args[0]);
    var delayFilter = (args.length >= 2 && args[1] !== '*') ? parseInt(args[1], 10) : -1;
    var origSetTimeout = window.setTimeout;

    window.setTimeout = function(fn, delay) {
      if (typeof fn === 'function' || typeof fn === 'string') {
        var str = typeof fn === 'function' ? String(fn) : fn;
        if (callbackMatcher.test(str)) {
          if (delayFilter === -1 || delay === delayFilter) {
            return 0;
          }
        }
      }
      return origSetTimeout.apply(this, arguments);
    };
  };

  // --- 11. prevent-setInterval ---
  _registry['prevent-setInterval'] = function(args) {
    if (!args || !args[0]) return;
    var callbackMatcher = compileRegex(args[0]);
    var origInterval = window.setInterval;

    window.setInterval = function(fn, delay) {
      if (typeof fn === 'function' || typeof fn === 'string') {
        var str = typeof fn === 'function' ? String(fn) : fn;
        if (callbackMatcher.test(str)) {
          return 0;
        }
      }
      return origInterval.apply(this, arguments);
    };
  };

  // --- 12. prevent-setTimeout ---
  _registry['prevent-setTimeout'] = function(args) {
    if (!args || !args[0]) return;
    var callbackMatcher = compileRegex(args[0]);
    var origSetTimeout = window.setTimeout;

    window.setTimeout = function(fn, delay) {
      if (typeof fn === 'function' || typeof fn === 'string') {
        var str = typeof fn === 'function' ? String(fn) : fn;
        if (callbackMatcher.test(str)) {
          return 0;
        }
      }
      return origSetTimeout.apply(this, arguments);
    };
  };

  // --- 13. remove-attr ---
  _registry['remove-attr'] = function(args) {
    if (!args || !args[0]) return;
    var attr = args[0];
    var selector = args.length >= 2 ? args[1] : '*';

    function stripAttrs() {
      try {
        var nodes = document.querySelectorAll(selector);
        for (var i = 0; i < nodes.length; i++) {
          nodes[i].removeAttribute(attr);
        }
      } catch (_) {}
    }

    stripAttrs();
    var observer = new MutationObserver(stripAttrs);
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(function() { observer.disconnect(); }, 6000);
    }
  };

  // --- 14. remove-class ---
  _registry['remove-class'] = function(args) {
    if (!args || !args[0]) return;
    var clsName = args[0];
    var selector = args.length >= 2 ? args[1] : '*';

    function stripClasses() {
      try {
        var nodes = document.querySelectorAll(selector);
        for (var i = 0; i < nodes.length; i++) {
          nodes[i].classList.remove(clsName);
        }
      } catch (_) {}
    }

    stripClasses();
    var observer = new MutationObserver(stripClasses);
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(function() { observer.disconnect(); }, 6000);
    }
  };

  // --- 15. no-referrer-when-downgrade ---
  _registry['no-referrer-when-downgrade'] = function() {
    try {
      if (!document.querySelector('meta[name="referrer"]')) {
        var meta = document.createElement('meta');
        meta.name = 'referrer';
        meta.content = 'no-referrer';
        var head = document.head || document.documentElement;
        if (head) head.appendChild(meta);
      }
      Object.defineProperty(HTMLAnchorElement.prototype, 'referrerPolicy', {
        get: function() { return 'no-referrer'; },
        set: function() {},
        configurable: true
      });
    } catch (_) {}
  };

  // --- 16. json-prune ---
  _registry['json-prune'] = function(args) {
    if (!args || !args.length) return;

    var filterMatchers = [];
    for (var i = 0; i < args.length; i++) {
      var item = args[i];
      if (!item) continue;
      var match = /^\/(.+)\/([a-z]*)$/.exec(item);
      if (match) {
        try { filterMatchers.push(new RegExp(match[1], match[2])); } catch (_) {}
      } else {
        filterMatchers.push(item);
      }
    }
    if (!filterMatchers.length) return;

    function deepPrune(data, currentPath) {
      if (!data || typeof data !== 'object') return;
      if (Array.isArray(data)) {
        for (var idx = 0; idx < data.length; idx++) {
          deepPrune(data[idx], currentPath);
        }
        return;
      }
      var keys = Object.keys(data);
      for (var k = 0; k < keys.length; k++) {
        var key = keys[k];
        var fullPath = currentPath ? currentPath + '.' + key : key;
        var shouldDrop = false;

        for (var f = 0; f < filterMatchers.length; f++) {
          var rule = filterMatchers[f];
          if (typeof rule === 'string') {
            if (rule.indexOf('.') === -1 ? key === rule : fullPath === rule) {
              shouldDrop = true;
              break;
            }
          } else if (rule.test(key) || rule.test(fullPath)) {
            shouldDrop = true;
            break;
          }
        }

        if (shouldDrop) {
          try { delete data[key]; } catch (_) {}
        } else {
          deepPrune(data[key], fullPath);
        }
      }
    }

    var origParse = JSON.parse;
    JSON.parse = function(text, reviver) {
      var parsed = origParse.call(this, text, reviver);
      try { deepPrune(parsed, ''); } catch (_) {}
      return parsed;
    };

    var origStringify = JSON.stringify;
    JSON.stringify = function(val, replacer, space) {
      try { deepPrune(val, ''); } catch (_) {}
      return origStringify.call(this, val, replacer, space);
    };
  };

  // --- 17. set-local-storage-item ---
  _registry['set-local-storage-item'] = function(args) {
    if (!args || args.length < 2) return;
    try {
      var existing = localStorage.getItem(args[0]);
      if (existing !== null && existing !== '' && existing !== args[1]) return;
      localStorage.setItem(args[0], args[1]);
    } catch (_) {}
  };

  // --- 18. trusted-set-local-storage-item ---
  _registry['trusted-set-local-storage-item'] = function(args) {
    if (!args || args.length < 2) return;
    try {
      localStorage.setItem(args[0], args[1]);
    } catch (_) {}
  };

  // --- 20. set-attr ---
  _registry['set-attr'] = function(args) {
    if (!args || args.length < 2) return;
    var attr = args[0];
    var val = args[1];
    var selector = args.length >= 3 ? args[2] : '*';

    function setAttributes() {
      try {
        var elements = document.querySelectorAll(selector);
        for (var i = 0; i < elements.length; i++) {
          if (val === 'removeattr') {
            elements[i].removeAttribute(attr);
          } else {
            elements[i].setAttribute(attr, val);
          }
        }
      } catch (_) {}
    }

    setAttributes();
    var observer = new MutationObserver(setAttributes);
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(function() { observer.disconnect(); }, 6000);
    }
  };

  // --- 21. prevent-refresh ---
  _registry['prevent-refresh'] = function() {
    function stripRefresh() {
      try {
        var metas = document.querySelectorAll('meta[http-equiv]');
        for (var i = 0; i < metas.length; i++) {
          if (metas[i].httpEquiv.toLowerCase() === 'refresh') {
            metas[i].remove();
          }
        }
      } catch (_) {}
    }

    stripRefresh();
    var observer = new MutationObserver(stripRefresh);
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(function() { observer.disconnect(); }, 6000);
    }

    try {
      if (window.Location && window.Location.prototype && window.Location.prototype.reload) {
        window.Location.prototype.reload = function() {};
      }
    } catch (_) {}
    try {
      if (window.location && window.location.reload) {
        window.location.reload = function() {};
      }
    } catch (_) {}
  };

})();
