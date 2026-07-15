import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';

typedef AuroraAdblockCreateC = Pointer<Void> Function();
typedef AuroraAdblockCreate = Pointer<Void> Function();

typedef AuroraAdblockLoadRulesC =
    Void Function(Pointer<Void> engine, Pointer<Utf8> rulesUtf8);
typedef AuroraAdblockLoadRules =
    void Function(Pointer<Void> engine, Pointer<Utf8> rulesUtf8);

typedef AuroraAdblockShouldBlockC =
    Int32 Function(Pointer<Void> engine, Pointer<Utf8> urlUtf8);
typedef AuroraAdblockShouldBlock =
    int Function(Pointer<Void> engine, Pointer<Utf8> urlUtf8);

typedef AuroraAdblockShouldBlockExC =
    Int32 Function(
      Pointer<Void> engine,
      Pointer<Utf8> urlUtf8,
      Pointer<Utf8> sourceHostUtf8,
      Pointer<Utf8> requestTypeUtf8,
      Int32 isThirdParty,
    );
typedef AuroraAdblockShouldBlockEx =
    int Function(
      Pointer<Void> engine,
      Pointer<Utf8> urlUtf8,
      Pointer<Utf8> sourceHostUtf8,
      Pointer<Utf8> requestTypeUtf8,
      int isThirdParty,
    );

typedef AuroraAdblockShouldHideElementC =
    Int32 Function(
      Pointer<Void> engine,
      Pointer<Utf8> pageHostUtf8,
      Pointer<Utf8> tagNameUtf8,
      Pointer<Utf8> idUtf8,
      Pointer<Utf8> classesUtf8,
    );
typedef AuroraAdblockShouldHideElement =
    int Function(
      Pointer<Void> engine,
      Pointer<Utf8> pageHostUtf8,
      Pointer<Utf8> tagNameUtf8,
      Pointer<Utf8> idUtf8,
      Pointer<Utf8> classesUtf8,
    );

typedef AuroraAdblockDestroyC = Void Function(Pointer<Void> engine);
typedef AuroraAdblockDestroy = void Function(Pointer<Void> engine);

class AdBlockFFIBindings {
  final DynamicLibrary lib;
  late final AuroraAdblockCreate createEngine;
  late final AuroraAdblockLoadRules loadRules;
  late final AuroraAdblockShouldBlock shouldBlock;
  late final AuroraAdblockShouldBlockEx shouldBlockEx;
  late final AuroraAdblockShouldHideElement shouldHideElement;
  late final AuroraAdblockDestroy destroyEngine;
  late final NativeFinalizer finalizer;

  AdBlockFFIBindings(this.lib) {
    createEngine = lib
        .lookupFunction<AuroraAdblockCreateC, AuroraAdblockCreate>(
          'aurora_adblock_create',
        );
    loadRules = lib
        .lookupFunction<AuroraAdblockLoadRulesC, AuroraAdblockLoadRules>(
          'aurora_adblock_load_rules',
        );
    shouldBlock = lib
        .lookupFunction<AuroraAdblockShouldBlockC, AuroraAdblockShouldBlock>(
          'aurora_adblock_should_block',
        );
    shouldBlockEx = lib
        .lookupFunction<
          AuroraAdblockShouldBlockExC,
          AuroraAdblockShouldBlockEx
        >('aurora_adblock_should_block_ex');
    shouldHideElement = lib
        .lookupFunction<
          AuroraAdblockShouldHideElementC,
          AuroraAdblockShouldHideElement
        >('aurora_adblock_should_hide_element');
    destroyEngine = lib
        .lookupFunction<AuroraAdblockDestroyC, AuroraAdblockDestroy>(
          'aurora_adblock_destroy',
        );
    finalizer = NativeFinalizer(
      lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'aurora_adblock_destroy',
      ),
    );
  }

  static AdBlockFFIBindings? load() {
    try {
      final DynamicLibrary lib;
      if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libaurora_adblock.so');
      } else {
        throw UnsupportedError(
          'The native adblocker only runs on Android.',
        );
      }
      return AdBlockFFIBindings(lib);
    } catch (e) {
      debugPrint('Failed to load native adblocker library: $e');
      return null;
    }
  }
}
