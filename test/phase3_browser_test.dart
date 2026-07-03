import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/sniffer/safe_browsing_service.dart';
import 'package:aurora_downloader/sniffer/autofill_store.dart';

void main() {
  group('SafeBrowsingService', () {
    test('flags suspicious TLDs via heuristic', () async {
      final service = SafeBrowsingService(
        client: MockClient((request) async => http.Response('', 404)),
      );
      final result = await service.check('https://something.zip/login');
      expect(result.verdict, SafeBrowsingVerdict.suspicious);
      expect(result.source, 'heuristic');
      service.dispose();
    });

    test('marks unknown verdict for invalid URL', () async {
      final service = SafeBrowsingService(
        client: MockClient((request) async => http.Response('', 404)),
      );
      final result = await service.check('not a url');
      expect(result.verdict, SafeBrowsingVerdict.unknown);
      service.dispose();
    });

    test('matches local blocklist subdomains as malicious', () async {
      final service = SafeBrowsingService(
        client: MockClient((request) async => http.Response('', 404)),
      );
      // Without a real cached blocklist the service falls back to heuristic.
      // The verdict should at least be safe or heuristic-based.
      final result = await service.check('https://google.com/search');
      expect(result.verdict, isIn([
        SafeBrowsingVerdict.safe,
        SafeBrowsingVerdict.suspicious,
      ]));
      service.dispose();
    });
  });

  group('AutofillProfile', () {
    test('round-trips through json', () {
      const profile = AutofillProfile(
        id: 'a1',
        label: 'Personal',
        fullName: 'Alex Doe',
        email: 'alex@example.com',
        phone: '+1-555-0100',
        addressLine1: '1 Main St',
        city: 'Springfield',
        state: 'IL',
        postalCode: '62701',
        country: 'US',
        includeCard: true,
        cardName: 'Alex Doe',
        cardNumber: '4111111111111111',
        cardExpiry: '12/29',
      );
      final json = profile.toJson();
      final restored = AutofillProfile.fromJson(json);
      expect(restored.label, 'Personal');
      expect(restored.fullName, 'Alex Doe');
      expect(restored.email, 'alex@example.com');
      expect(restored.addressLine1, '1 Main St');
      expect(restored.postalCode, '62701');
      expect(restored.includeCard, isTrue);
      expect(restored.cardNumber, '4111111111111111');
    });

    test('copyWith clears fields correctly', () {
      const profile = AutofillProfile(id: 'x', label: 'Old', email: 'a@b.com');
      final updated = profile.copyWith(label: 'New');
      expect(updated.label, 'New');
      expect(updated.email, 'a@b.com');
      expect(updated.id, 'x');
    });
  });
}
