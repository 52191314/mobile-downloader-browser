(function() {
  'use strict';

  // Prevent re-execution
  if (window.__auroraCosmeticApplied) return;

  var _configStyle = null;
  var _observer = null;
  var _scheduled = false;

  // Called by Dart via evaluateJavascript to set cosmetic CSS for the page.
  // The css parameter is a string of CSS rules (display:none + injection rules).
  window.__auroraSetCosmeticCss = function(css) {
    if (!css) return;

    // Remove old style if exists
    if (_configStyle) {
      _configStyle.remove();
      _configStyle = null;
    }

    // Store config for MutationObserver
    window.__auroraCosmeticConfig = { css: css };

    // Create and inject new <style> element
    _configStyle = document.createElement('style');
    _configStyle.setAttribute('type', 'text/css');
    _configStyle.setAttribute('data-aurora-cosmetic', '');
    _configStyle.textContent = css;

    var target = document.head || document.documentElement;
    if (target) {
      target.appendChild(_configStyle);
    }

    // Immediately hide matching elements
    sweepNow(css);

    // Start MutationObserver for dynamically added elements
    startObserver(css);
  };

  // Extract selectors from CSS rules and hide matching elements immediately
  function sweepNow(css) {
    if (!css) return;
    try {
      var ruleRegex = /([^{]+)\{display\s*:\s*none\s*!important\s*\}/g;
      var match;
      while ((match = ruleRegex.exec(css)) !== null) {
        var selector = match[1].trim();
        if (selector) {
          try {
            var elements = document.querySelectorAll(selector);
            for (var i = 0; i < elements.length; i++) {
              elements[i].style.setProperty('display', 'none', 'important');
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // Extract individual selectors from CSS display:none rules
  function extractSelectors(css) {
    var selectors = [];
    try {
      var ruleRegex = /([^{]+)\{display\s*:\s*none\s*!important\s*\}/g;
      var match;
      while ((match = ruleRegex.exec(css)) !== null) {
        var parts = match[1].split(',');
        for (var i = 0; i < parts.length; i++) {
          var s = parts[i].trim();
          if (s) selectors.push(s);
        }
      }
    } catch (_) {}
    return selectors;
  }

  // MutationObserver to catch dynamically-added ad elements
  function startObserver(css) {
    if (_observer) return;

    var selectors = extractSelectors(css);
    if (selectors.length === 0) return;

    var selectorStr = selectors.join(',');

    _observer = new MutationObserver(function(mutations) {
      var needsSweep = false;
      for (var i = 0; i < mutations.length; i++) {
        if (mutations[i].addedNodes.length > 0) {
          needsSweep = true;
          break;
        }
      }
      if (needsSweep && !_scheduled) {
        _scheduled = true;
        requestAnimationFrame(function() {
          _scheduled = false;
          try {
            var elements = document.querySelectorAll(selectorStr);
            for (var i = 0; i < elements.length; i++) {
              if (elements[i].style.display !== 'none') {
                elements[i].style.setProperty('display', 'none', 'important');
              }
            }
          } catch (_) {}
        });
      }
    });

    if (document.documentElement) {
      _observer.observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    }

    // Disconnect observer after 10 seconds to avoid long-term performance impact
    setTimeout(function() {
      if (_observer) {
        _observer.disconnect();
        _observer = null;
      }
    }, 10000);
  }

  // Auto-apply if config was set via UserScript before DOM ready
  if (window.__auroraCosmeticConfig && window.__auroraCosmeticConfig.css) {
    window.__auroraSetCosmeticCss(window.__auroraCosmeticConfig.css);
  }

  window.__auroraCosmeticApplied = true;
})();
