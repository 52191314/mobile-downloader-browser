(function() {
  'use strict';

  // ---------------------------------------------------------------
  // Aurora Scriptlet Engine — curated subset of AdGuard scriptlets
  // Adapted from @adguard/scriptlets (GPL-3.0)
  // ---------------------------------------------------------------
  // Scriptlets patch browser APIs to prevent anti-adblock detection.
  // They run at document_start, before any page script executes.
  // ---------------------------------------------------------------

  var _registry = {};
  var _invoked = {};

  // --- Utilities --------------------------------------------------

  function randomId() {
    return Math.random().toString(36).slice(2, 9);
  }

  // Convert a regex pattern string to a RegExp object.
  // Supports both /pattern/flags notation and plain strings.
  function toRegExp(pattern) {
    if (!pattern || pattern === '') return new RegExp('.?');
    // /pattern/flags notation
    if (pattern.startsWith('/') && pattern.lastIndexOf('/') > 0) {
      var lastSlash = pattern.lastIndexOf('/');
      var body = pattern.slice(1, lastSlash);
      var flags = pattern.slice(lastSlash + 1);
      try { return new RegExp(body, flags); } catch (_) {}
    }
    // Plain string — escape special characters
    var escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(escaped);
  }

  // Get a property from a chain (e.g. 'window.foo.bar')
  function getPropInChain(obj, chain) {
    var parts = chain.split('.');
    var current = obj;
    for (var i = 0; i < parts.length; i++) {
      if (current == null) return undefined;
      current = current[parts[i]];
    }
    return current;
  }

  // Set a property in a chain, creating intermediate objects as needed
  function setPropInChain(obj, chain, value) {
    var parts = chain.split('.');
    var current = obj;
    for (var i = 0; i < parts.length - 1; i++) {
      if (current[parts[i]] == null) {
        current[parts[i]] = {};
      }
      current = current[parts[i]];
    }
    current[parts[parts.length - 1]] = value;
  }

  // Override a property with a getter/setter that throws ReferenceError
  function abortProperty(obj, prop, onRead, onWrite) {
    var origValue = obj[prop];
    var rid = randomId();

    Object.defineProperty(obj, prop, {
      get: onRead ? function() {
        throw new ReferenceError(rid);
      } : function() { return origValue; },
      set: onWrite ? function() { throw new ReferenceError(rid); } : function(v) { origValue = v; },
      configurable: true,
      enumerable: true
    });

    // Catch the ReferenceError to suppress it
    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.includes(rid)) return true;
      if (origOnError) return origOnError.apply(window, arguments);
      return false;
    };
    return rid;
  }

  // --- Scriptlet Invocation ---------------------------------------

  var __auroraScriptlets = {
    invoke: function(name, args) {
      var key = name + '_' + (args ? args.join('_') : '');
      if (_invoked[key]) return;
      _invoked[key] = true;

      var fn = _registry[name];
      if (fn) {
        try {
          fn(args || []);
        } catch (_) {}
      }
    }
  };

  window.__auroraScriptlets = __auroraScriptlets;

  // ===============================================================
  // SCRIPLET 1: abort-on-property-read
  // Throws ReferenceError when a target property is read.
  // Usage: abort-on-property-read('window.property')
  // ===============================================================
  _registry['abort-on-property-read'] = function(args) {
    if (!args || !args[0]) return;
    var prop = args[0];
    var parts = prop.split('.');
    if (parts.length < 2) return;
    var objName = parts.slice(0, -1).join('.');
    var propName = parts[parts.length - 1];

    var target = window;
    for (var i = 0; i < parts.length - 1; i++) {
      if (target[parts[i]] == null) {
        // Create intermediate object
        target[parts[i]] = {};
      }
      target = target[parts[i]];
    }

    var origValue = target[propName];
    var rid = randomId();
    Object.defineProperty(target, propName, {
      get: function() { throw new ReferenceError(rid); },
      set: function(v) { origValue = v; },
      configurable: true
    });

    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.includes(rid)) return true;
      if (origOnError) return origOnError.apply(window, arguments);
      return false;
    };
  };

  // ===============================================================
  // SCRIPLET 2: abort-on-property-write
  // Throws ReferenceError when a target property is written.
  // Usage: abort-on-property-write('window.property')
  // ===============================================================
  _registry['abort-on-property-write'] = function(args) {
    if (!args || !args[0]) return;
    var prop = args[0];
    var parts = prop.split('.');
    if (parts.length < 2) return;

    var target = window;
    for (var i = 0; i < parts.length - 1; i++) {
      if (target[parts[i]] == null) return;
      target = target[parts[i]];
    }
    var propName = parts[parts.length - 1];
    var rid = randomId();

    Object.defineProperty(target, propName, {
      get: function() { return undefined; },
      set: function() { throw new ReferenceError(rid); },
      configurable: true
    });

    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.includes(rid)) return true;
      if (origOnError) return origOnError.apply(window, arguments);
      return false;
    };
  };

  // ===============================================================
  // SCRIPLET 3: abort-current-inline-script
  // Aborts an inline script element whose content matches a pattern.
  // Usage: abort-current-inline-script('property', 'searchPattern')
  // ===============================================================
  _registry['abort-current-inline-script'] = function(args) {
    if (!args || !args[0] || !args[1]) return;
    var property = args[0];
    var search = args[1];
    var searchRegexp = toRegExp(search);

    var rid = randomId();

    // Override the property so that when it's accessed on a script,
    // if the script's textContent matches the pattern, we abort.
    var parts = property.split('.');
    if (parts.length < 2) return;

    var obj = window;
    for (var i = 0; i < parts.length - 1; i++) {
      if (obj[parts[i]] == null) return;
      obj = obj[parts[i]];
    }
    var propName = parts[parts.length - 1];

    var nativeFn = obj[propName];
    if (typeof nativeFn !== 'function') return;

    obj[propName] = function() {
      // Check if we can access the current script
      try {
        var script = document.currentScript;
        if (script && script.textContent) {
          if (searchRegexp.test(script.textContent)) {
            throw new ReferenceError(rid);
          }
        }
      } catch (e) {
        if (e instanceof ReferenceError && e.message === rid) {
          throw e;
        }
      }
      return nativeFn.apply(this, arguments);
    };

    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.includes(rid)) {
        // Suppress the error — the inline script is aborted
        return true;
      }
      if (origOnError) return origOnError.apply(window, arguments);
      return false;
    };
  };

  // ===============================================================
  // SCRIPLET 4: set-constant
  // Overrides a property with a constant value to prevent
  // anti-adblock detection (e.g. canRunAds = true).
  // Usage: set-constant('window.property', 'value')
  // ===============================================================
  _registry['set-constant'] = function(args) {
    if (!args || !args[0]) return;
    var prop = args[0];
    var value = args.length >= 2 ? args[1] : 'true';

    // Parse value
    var parsedValue;
    if (value === 'true') parsedValue = true;
    else if (value === 'false') parsedValue = false;
    else if (value === 'undefined') parsedValue = undefined;
    else if (value === 'null') parsedValue = null;
    else if (value === 'noopFunc' || value === 'noopCallback') {
      parsedValue = function() {};
    } else if (value === 'trueFunc') {
      parsedValue = function() { return true; };
    } else if (value === 'falseFunc') {
      parsedValue = function() { return false; };
    } else if (!isNaN(Number(value))) {
      parsedValue = Number(value);
    } else {
      parsedValue = value;
    }

    var parts = prop.split('.');
    if (parts.length < 2) return;

    var target = window;
    for (var i = 0; i < parts.length - 1; i++) {
      if (target[parts[i]] == null) {
        target[parts[i]] = {};
      }
      target = target[parts[i]];
    }
    var propName = parts[parts.length - 1];

    Object.defineProperty(target, propName, {
      get: function() { return parsedValue; },
      set: function() {},
      configurable: true
    });
  };

  // ===============================================================
  // SCRIPLET 5: prevent-addEventListener
  // Blocks event listeners from being registered when the event type
  // matches a pattern.
  // Usage: prevent-addEventListener('click', 'searchPattern')
  // ===============================================================
  _registry['prevent-addEventListener'] = function(args) {
    if (!args || !args[0]) return;

    var eventTypeFilter = toRegExp(args[0]);
    var handlerFilter = args.length >= 2 ? toRegExp(args[1]) : null;

    var nativeAddEventListener = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(type, listener, options) {
      if (eventTypeFilter.test(type)) {
        // If handler filter is specified, also check the handler
        if (handlerFilter && listener) {
          var handlerStr = listener.toString();
          if (!handlerFilter.test(handlerStr)) {
            return nativeAddEventListener.call(this, type, listener, options);
          }
        }
        // Block this event listener
        return;
      }
      return nativeAddEventListener.call(this, type, listener, options);
    };
  };

  // ===============================================================
  // SCRIPLET 6: noeval
  // Blocks eval() calls.
  // Usage: noeval()
  // ===============================================================
  _registry['noeval'] = function() {
    var rid = randomId();
    var nativeEval = window.eval;
    window.eval = function() {
      throw new ReferenceError(rid);
    };
    // Also block Function constructor
    var nativeFunction = window.Function;
    window.Function = function() {
      throw new ReferenceError(rid);
    };

    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.includes(rid)) return true;
      if (origOnError) return origOnError.apply(window, arguments);
      return false;
    };
  };

  // ===============================================================
  // SCRIPLET 7: no-fetch-if
  // Blocks fetch() requests whose URL matches a pattern.
  // Usage: no-fetch-if('pattern')
  // ===============================================================
  _registry['no-fetch-if'] = function(args) {
    if (!args || !args[0]) return;
    var pattern = toRegExp(args[0]);

    var nativeFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = typeof input === 'string' ? input :
                input instanceof Request ? input.url : '';
      if (url && pattern.test(url)) {
        return Promise.reject(new Error('Blocked by adblocker'));
      }
      return nativeFetch.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 8: no-xhr-if
  // Blocks XMLHttpRequest calls whose URL matches a pattern.
  // Usage: no-xhr-if('pattern')
  // ===============================================================
  _registry['no-xhr-if'] = function(args) {
    if (!args || !args[0]) return;
    var pattern = toRegExp(args[0]);

    var nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      if (pattern.test(url)) {
        // Abort this request — don't even open it
        return;
      }
      return nativeOpen.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 9: no-window-open-if
  // Blocks window.open calls whose URL matches a pattern.
  // Usage: no-window-open-if('pattern')
  // ===============================================================
  _registry['no-window-open-if'] = function(args) {
    if (!args || !args[0]) return;
    var pattern = toRegExp(args[0]);

    var nativeOpen = window.open;
    window.open = function(url, name, features) {
      if (pattern.test(url)) {
        return null;
      }
      return nativeOpen.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 10: set-timeout-defuser
  // Blocks setTimeout calls whose callback matches a pattern.
  // Usage: set-timeout-defuser('pattern')
  // ===============================================================
  _registry['set-timeout-defuser'] = function(args) {
    if (!args || !args[0]) return;
    var callbackPattern = toRegExp(args[0]);
    var delayPattern = args.length >= 2 && args[1] !== '*' ? parseInt(args[1], 10) : -1;

    var nativeSetTimeout = window.setTimeout;
    window.setTimeout = function(callback, delay) {
      var match = false;
      if (typeof callback === 'function' || typeof callback === 'string') {
        var callbackStr = typeof callback === 'function' ? callback.toString() : callback;
        if (callbackPattern.test(callbackStr)) {
          if (delayPattern === -1 || delay === delayPattern) {
            match = true;
          }
        }
      }
      if (match) {
        // Return a timer ID that will be ignored
        return 0;
      }
      return nativeSetTimeout.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 11: prevent-setInterval
  // Blocks setInterval calls whose callback matches a pattern.
  // Usage: prevent-setInterval('pattern')
  // ===============================================================
  _registry['prevent-setInterval'] = function(args) {
    if (!args || !args[0]) return;
    var callbackPattern = toRegExp(args[0]);

    var nativeSetInterval = window.setInterval;
    window.setInterval = function(callback, delay) {
      if (typeof callback === 'function' || typeof callback === 'string') {
        var callbackStr = typeof callback === 'function' ? callback.toString() : callback;
        if (callbackPattern.test(callbackStr)) {
          return 0;
        }
      }
      return nativeSetInterval.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 12: prevent-setTimeout
  // Blocks setTimeout calls whose callback matches a pattern.
  // Usage: prevent-setTimeout('pattern')
  // ===============================================================
  _registry['prevent-setTimeout'] = function(args) {
    if (!args || !args[0]) return;
    var callbackPattern = toRegExp(args[0]);

    var nativeSetTimeout = window.setTimeout;
    window.setTimeout = function(callback, delay) {
      if (typeof callback === 'function' || typeof callback === 'string') {
        var callbackStr = typeof callback === 'function' ? callback.toString() : callback;
        if (callbackPattern.test(callbackStr)) {
          return 0;
        }
      }
      return nativeSetTimeout.apply(this, arguments);
    };
  };

  // ===============================================================
  // SCRIPLET 13: remove-attr
  // Removes a specified attribute from elements matching a selector.
  // Usage: remove-attr('attribute', 'selector')
  // ===============================================================
  _registry['remove-attr'] = function(args) {
    if (!args || !args[0]) return;
    var attrName = args[0];
    var selector = args.length >= 2 ? args[1] : '*';

    function removeAttrFromMatching() {
      try {
        var elements = document.querySelectorAll(selector);
        for (var i = 0; i < elements.length; i++) {
          elements[i].removeAttribute(attrName);
        }
      } catch (_) {}
    }

    // Run immediately
    removeAttrFromMatching();

    // Run on DOM mutations
    var observer = new MutationObserver(function() {
      removeAttrFromMatching();
    });
    if (document.documentElement) {
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    }
    // Disconnect after 5 seconds
    setTimeout(function() { observer.disconnect(); }, 5000);
  };

  // ===============================================================
  // SCRIPLET 14: remove-class
  // Removes a specified class from elements matching a selector.
  // Usage: remove-class('className', 'selector')
  // ===============================================================
  _registry['remove-class'] = function(args) {
    if (!args || !args[0]) return;
    var className = args[0];
    var selector = args.length >= 2 ? args[1] : '*';

    function removeClassFromMatching() {
      try {
        var elements = document.querySelectorAll(selector);
        for (var i = 0; i < elements.length; i++) {
          elements[i].classList.remove(className);
        }
      } catch (_) {}
    }

    // Run immediately
    removeClassFromMatching();

    // Run on DOM mutations
    var observer = new MutationObserver(function() {
      removeClassFromMatching();
    });
    if (document.documentElement) {
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    }
    // Disconnect after 5 seconds
    setTimeout(function() { observer.disconnect(); }, 5000);
  };

  // ===============================================================
  // SCRIPLET 15: no-referrer-when-downgrade
  // Prevents referrer leakage by setting meta referrer policy.
  // Usage: no-referrer-when-downgrade()
  // ===============================================================
  _registry['no-referrer-when-downgrade'] = function() {
    // The browser already has a default behaviour; this scriptlet
    // strengthens it by setting the meta tag explicitly.
    if (!document.querySelector('meta[name="referrer"]')) {
      var meta = document.createElement('meta');
      meta.name = 'referrer';
      meta.content = 'no-referrer';
      var target = document.head || document.documentElement;
      if (target) {
        target.appendChild(meta);
      }
    }

    // Also override the referrer property on any anchor/area elements
    Object.defineProperty(HTMLAnchorElement.prototype, 'referrerPolicy', {
      get: function() { return 'no-referrer'; },
      set: function() {},
      configurable: true
    });
  };

})();
