import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/actions/context_menu_action.dart';

void main() {
  group('classifyContextMenuPayload', () {
    test('ignores legacy popup-shaped link context payloads', () {
      expect(
        classifyContextMenuPayload({
          'href': 'https://ads.example/popup',
          'src': '',
          'selectedText': '',
          'tagName': 'a',
          'selector': '',
        }),
        ContextMenuTargetKind.ignored,
      );
    });

    test('classifies links, media, linked media, text, and page payloads', () {
      expect(
        classifyContextMenuPayload({
          'href': 'https://example.com/page',
          'selector': 'a.cta',
          'tagName': 'a',
        }),
        ContextMenuTargetKind.link,
      );
      expect(
        classifyContextMenuPayload({
          'src': 'https://example.com/image.jpg',
          'selector': 'img.hero',
          'tagName': 'img',
        }),
        ContextMenuTargetKind.media,
      );
      expect(
        classifyContextMenuPayload({
          'href': 'https://example.com/page',
          'src': 'https://example.com/image.jpg',
          'selector': 'a.hero > img',
          'tagName': 'img',
        }),
        ContextMenuTargetKind.linkedMedia,
      );
      expect(
        classifyContextMenuPayload({'selectedText': 'hello world'}),
        ContextMenuTargetKind.textSelection,
      );
      expect(
        classifyContextMenuPayload({'pageUrl': 'https://example.com'}),
        ContextMenuTargetKind.page,
      );
    });
  });
}
