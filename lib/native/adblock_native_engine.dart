import 'dart:ffi';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import '../logging/aurora_log.dart';
import 'adblock_ffi.dart';

class AdBlockNativeEngine implements Finalizable {
  final AdBlockFFIBindings _bindings;
  final Pointer<Void> _enginePtr;
  bool _isDestroyed = false;

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
    final urlPtr = url.toNativeUtf8();
    try {
      return _bindings.shouldBlock(_enginePtr, urlPtr) == 1;
    } catch (e) {
      debugPrint('Error checking URL with native engine: $e');
      AuroraLog.instance.error(
        'Error checking URL with native engine: $e',
        category: LogCategory.native,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return false;
    } finally {
      malloc.free(urlPtr);
    }
  }

  bool shouldBlockUrlEx(
    String url, {
    required String sourceHost,
    required String requestType,
    required bool isThirdParty,
  }) {
    if (_isDestroyed) return false;
    final urlPtr = url.toNativeUtf8();
    final hostPtr = sourceHost.toNativeUtf8();
    final typePtr = requestType.toNativeUtf8();
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
      AuroraLog.instance.error(
        'Error checking URL Ex with native engine: $e',
        category: LogCategory.native,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return false;
    } finally {
      malloc.free(urlPtr);
      malloc.free(hostPtr);
      malloc.free(typePtr);
    }
  }

  bool shouldHideElement({
    required String pageHost,
    required String tagName,
    required String id,
    required List<String> classes,
  }) {
    if (_isDestroyed) return false;
    final hostPtr = pageHost.toNativeUtf8();
    final tagPtr = tagName.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    final classesPtr = classes.join(' ').toNativeUtf8();
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
      AuroraLog.instance.error(
        'Error checking element hiding with native engine: $e',
        category: LogCategory.native,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return false;
    } finally {
      malloc.free(hostPtr);
      malloc.free(tagPtr);
      malloc.free(idPtr);
      malloc.free(classesPtr);
    }
  }

  void destroy() {
    if (_isDestroyed) return;
    _bindings.finalizer.detach(this);
    _bindings.destroyEngine(_enginePtr);
    _isDestroyed = true;
  }
}
