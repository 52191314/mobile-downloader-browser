// Temp verification harness for the mini-player + link-preview features.
// Run from the repo root: flutter test "C:\Users\Xian\AppData\Local\Temp\hermes-verify_miniplayer_preview_test.dart"
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';
import 'package:aurora_downloader/sniffer/player/playback_engine.dart';
import 'package:aurora_downloader/sniffer/player/playback_source.dart';
import 'package:aurora_downloader/sniffer/player/playback_state.dart';
import 'package:aurora_downloader/sniffer/player/mini_player_controller.dart';
import 'package:aurora_downloader/sniffer/widgets/mini_player_overlay.dart';
import 'package:aurora_downloader/sniffer/actions/context_menu_action.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';

class _FakeEngine implements PlaybackEngine {
  _FakeEngine()
      : state = ValueNotifier<PlaybackState>(
          const PlaybackState(
            status: PlaybackStatus.ready,
            isPlaying: true,
          ),
        );

  @override
  final ValueNotifier<PlaybackState> state;

  int playCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;
  final List<Duration> seekPositions = [];

  @override
  PlaybackEngineKind get kind => PlaybackEngineKind.videoPlayer;

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> play() async {
    playCalls++;
    state.value = state.value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    state.value = state.value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekPositions.add(position);
    state.value = state.value.copyWith(position: position);
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Widget buildSurface({BoxFit fit = BoxFit.contain}) =>
      const ColoredBox(key: Key('fake_surface'), color: Colors.blue);

  @override
  bool get supportsScrubPreview => false;

  @override
  bool get scrubPreviewReady => false;

  @override
  Future<void> prepareScrubPreview() async {}

  @override
  Future<void> seekScrubPreview(Duration position) async {}

  @override
  Widget? buildScrubPreview() => null;

  @override
  Map<String, Object?> diagnostics() => const {};

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

Future<void> _pumpOverlay(WidgetTester tester, _FakeEngine engine) async {
  await tester.pumpWidget(
    AuroraPalette(
      isLight: false,
      colors: AColors.dark(),
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              MiniPlayerOverlay(onExpand: () {}),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => MiniPlayerController.instance.reset());

  test('mini player controller adopt/close lifecycle', () async {
    final c = MiniPlayerController.instance;
    c.reset();
    final engine = _FakeEngine();
    expect(c.isActive, isFalse);

    c.adopt(engine, const PlaybackSource(url: 'https://x/v.mp4'));
    expect(c.isActive, isTrue);
    expect(c.engine, same(engine));
    expect(c.source!.url, 'https://x/v.mp4');

    // Adopting the same engine again (double PIP-exit callback) is a no-op.
    c.adopt(engine, const PlaybackSource(url: 'https://x/other.mp4'));
    expect(c.source!.url, 'https://x/v.mp4');

    await c.close();
    expect(c.isActive, isFalse);
    expect(engine.disposeCalls, 1);

    // Closing when idle is safe.
    await c.close();
    expect(engine.disposeCalls, 1);
  });

  testWidgets('mini player overlay renders, toggles, closes', (tester) async {
    final c = MiniPlayerController.instance;
    c.reset();
    final engine = _FakeEngine();
    c.adopt(engine, const PlaybackSource(url: 'https://x/v.mp4'));

    await _pumpOverlay(tester, engine);

    expect(find.byKey(const Key('fake_surface')), findsOneWidget);

    // Pause via the overlay button.
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(engine.pauseCalls, 1);

    // Resume.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(engine.playCalls, 1);

    // Close disposes the engine and hides the overlay.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(engine.disposeCalls, 1);
    expect(find.byKey(const Key('fake_surface')), findsNothing);
  });

  testWidgets('mini player restarts an ended video on play', (tester) async {
    final c = MiniPlayerController.instance;
    c.reset();
    final engine = _FakeEngine();
    // Simulate an ended video: sitting on the last frame, not playing.
    engine.state.value = engine.state.value.copyWith(
      isPlaying: false,
      position: const Duration(seconds: 60),
      duration: const Duration(seconds: 60),
    );
    c.adopt(engine, const PlaybackSource(url: 'https://x/v.mp4'));

    await _pumpOverlay(tester, engine);

    // Play at end must restart from the beginning instead of no-oping.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(engine.seekPositions, [Duration.zero]);
    expect(engine.playCalls, 1);

    // Mid-video pause → play resumes without a seek.
    engine.state.value = engine.state.value.copyWith(
      isPlaying: false,
      position: const Duration(seconds: 10),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(engine.seekPositions, [Duration.zero]); // no extra seek
    expect(engine.playCalls, 2);

    c.reset();
  });

  testWidgets('mini player overlay expands on video tap and drags',
      (tester) async {
    final c = MiniPlayerController.instance;
    c.reset();
    final engine = _FakeEngine();
    c.adopt(engine, const PlaybackSource(url: 'https://x/v.mp4'));
    var expanded = 0;

    await tester.pumpWidget(
      AuroraPalette(
        isLight: false,
        colors: AColors.dark(),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                MiniPlayerOverlay(onExpand: () => expanded++),
              ],
            ),
          ),
        ),
      ),
    );

    // Tap the video → expand callback fires.
    await tester.tap(find.byKey(const Key('fake_surface')));
    await tester.pump();
    expect(expanded, 1);

    // Drag up-left → the card actually moves (position persists, clamped).
    final before = tester.getTopLeft(find.byKey(const Key('mini_player_card')));
    await tester.drag(
      find.byKey(const Key('mini_player_card')),
      const Offset(-60, -80),
    );
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const Key('mini_player_card')));
    expect(after.dx, lessThan(before.dx));
    expect(after.dy, lessThan(before.dy));

    c.reset();
  });

  testWidgets('context menu shows Preview and fires onOpenPreview',
      (tester) async {
    final tab = BrowserTab(
      id: 't1',
      controller: MockBrowserController(),
      snifferEngine: MediaSnifferEngine(),
      addressController: TextEditingController(text: 'https://site/page'),
    );
    addTearDown(tab.dispose);
    String? opened;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showElementContextMenu(
                  context,
                  jsonEncode({
                    'href': 'https://site/target',
                    'tagName': 'a',
                    'text': 'Target',
                    'selector': 'a[href*="target"]',
                  }),
                  activeTab: tab,
                  isContextMenuShowing: false,
                  onContextMenuShowingChanged: (_) {},
                  onHandlePickedElement: (_) async {},
                  onCopyText: (_, __) async {},
                  onOpenNewTab: ({url, switchToTab = true}) {},
                  onOpenPreview: (url) async => opened = url,
                  onCopyCurrentUrl: () async {},
                  onToggleFavorite: () async {},
                  onSaveCurrentPage: () async {},
                  onShowSnack: (_) {},
                  onLoadUrl: (_) async {},
                  onAddToQueue: (_, __) {},
                  onTranslateText: (_) async {},
                  onSearchText: (_) async {},
                  isCurrentPageFavorited: false,
                  isMounted: true,
                ),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsOneWidget);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(opened, 'https://site/target');
  });

  test('classifyContextMenuPayload still classifies links', () {
    expect(
      classifyContextMenuPayload({
        'href': 'https://site/target',
        'tagName': 'a',
        'selector': 'a[href*="target"]',
      }),
      ContextMenuTargetKind.link,
    );
  });
}
