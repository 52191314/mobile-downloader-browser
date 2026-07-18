import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';

import 'adblock_ffi.dart';

/// Reusable UTF-8 scratch buffer for high-frequency FFI string args.
///
/// Avoids malloc/free on every [AdBlockNativeEngine.shouldBlockUrlEx] call
/// by growing a single buffer and rewriting it in place.
class _Utf8Scratch {
  Pointer<Uint8> _ptr = nullptr;
  int _capacity = 0;

  Pointer<Utf8> encode(String value) {
    final units = utf8.encode(value);
    final needed = units.length + 1; // NUL terminator
    if (needed > _capacity) {
      if (_ptr != nullptr) {
        malloc.free(_ptr);
      }
      // Grow with headroom so common URL lengths settle quickly.
      _capacity = needed < 64 ? 64 : needed * 2;
      _ptr = malloc.allocate<Uint8>(_capacity);
    }
    final view = _ptr.asTypedList(_capacity);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    return _ptr.cast<Utf8>();
  }

  void dispose() {
    if (_ptr != nullptr) {
      malloc.free(_ptr);
      _ptr = nullptr;
      _capacity = 0;
    }
  }
}

class AdBlockNativeEngine implements Finalizable {
  final AdBlockFFIBindings _bindings;
  final Pointer<Void> _enginePtr;
  bool _isDestroyed = false;

  // Per-engine scratch buffers for the hot shouldBlockUrlEx path (3 strings).
  // Dart WebView intercepts are single-threaded on the UI isolate, so one
  // set of buffers is safe without locks.
  final _Utf8Scratch _urlScratch = _Utf8Scratch();
  final _Utf8Scratch _hostScratch = _Utf8Scratch();
  final _Utf8Scratch _typeScratch = _Utf8Scratch();

  // Cached request-type / common host pointers for hide-element path.
  final Map<String, Pointer<Utf8>> _stringCache = {};

  AdBlockNativeEngine(this._bindings) : _enginePtr = _bindings.createEngine() {
    _bindings.finalizer.attach(this, _enginePtr, detach: this);
  }

  void loadRules(String rulesText) {
    if (_isDestroyed) return;
    final rulesPtr = rulesText.toNativeUtf8();
    try {
      _bindings.loadRules(_enginePtr, rulesPtr);
    } finally {
      malloc.free(rulesPtr);
    }
  }

  bool shouldBlockUrl(String url) {
    if (_isDestroyed) return false;
    final urlPtr = _urlScratch.encode(url);
    try {
      return _bindings.shouldBlock(_enginePtr, urlPtr) == 1;
    } catch (e) {
      debugPrint('Error checking URL with native engine: $e');
      return false;
    }
  }

  bool shouldBlockUrlEx(
    String url, {
    required String sourceHost,
    required String requestType,
    required bool isThirdParty,
  }) {
    if (_isDestroyed) return false;
    final urlPtr = _urlScratch.encode(url);
    final hostPtr = _hostScratch.encode(sourceHost);
    final typePtr = _typeScratch.encode(requestType);
    try {
      return _bindings.shouldBlockEx(
            _enginePtr,
            urlPtr,
            hostPtr,
            typePtr,
            isThirdParty ? 1 : 0,
          ) ==
          1;
    } catch (e) {
      debugPrint('Error checking URL Ex with native engine: $e');
      return false;
    }
  }

  bool shouldHideElement({
    required String pageHost,
    required String tagName,
    required String id,
    required List<String> classes,
  }) {
    if (_isDestroyed) return false;
    // Element-hide checks are less frequent; cache small stable strings.
    final hostPtr = _cachedUtf8(pageHost);
    final tagPtr = _cachedUtf8(tagName);
    final idPtr = _cachedUtf8(id);
    final classesJoined = classes.join(' ');
    final classesPtr = _cachedUtf8(classesJoined);
    try {
      return _bindings.shouldHideElement(
            _enginePtr,
            hostPtr,
            tagPtr,
            idPtr,
            classesPtr,
          ) ==
          1;
    } catch (e) {
      debugPrint('Error checking element hiding with native engine: $e');
      return false;
    }
  }

  Pointer<Utf8> _cachedUtf8(String value) {
    final existing = _stringCache[value];
    if (existing != null) return existing;
    final ptr = value.toNativeUtf8();
    // Cap cache size to avoid unbounded growth on unique class strings.
    if (_stringCache.length >= 256) {
      final firstKey = _stringCache.keys.first;
      final old = _stringCache.remove(firstKey);
      if (old != null) malloc.free(old);
    }
    _stringCache[value] = ptr;
    return ptr;
  }

  void destroy() {
    if (_isDestroyed) return;
    _bindings.finalizer.detach(this);
    _bindings.destroyEngine(_enginePtr);
    _urlScratch.dispose();
    _hostScratch.dispose();
    _typeScratch.dispose();
    for (final ptr in _stringCache.values) {
      malloc.free(ptr);
    }
    _stringCache.clear();
    _isDestroyed = true;
  }
}
