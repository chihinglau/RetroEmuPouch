import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/account/account_backend.dart'
    show AccountStore;
import 'package:retroemupouch/features/legal/cloud_config_service.dart';
import 'package:retroemupouch/features/legal/legal_constants.dart';

// Pins the on-disk cache contract introduced on 2026-11-05: opening a page
// must NOT hit the network while the 24h TTL is valid, and an unreachable
// backend must fall back to the last cached value instead of blanking the UI.

// These are the literal AccountStore keys written by CloudConfigService.
const String _kConfigs = 'cms_configs_json';
const String _kConfigsAt = 'cms_configs_at';
const String _kPolicyDoc = 'cms_doc_privacy_policy_zh';
const String _kPolicyDocAt = 'cms_doc_privacy_policy_zh_at';

/// Runs [body] with every HttpClient creation failing, so a cache hit is
/// provable (requests stays empty) and a miss cannot reach the real backend.
Future<T> _offline<T>(Future<T> Function() body, List<int> requests) {
  return HttpOverrides.runZoned<Future<T>>(
    body,
    createHttpClient: (SecurityContext? _) {
      requests.add(1);
      throw SocketException('offline in test');
    },
  );
}

void main() {
  late Map<String, Object> disk;
  late CloudConfigService svc;
  late List<int> requests;

  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  setUp(() {
    disk = <String, Object>{};
    requests = <int>[];
    svc = CloudConfigService.instance;
    svc.resetForTest();
    // AccountStore.fallback keeps the SAME map reference: mutations in a test
    // are immediately visible to the service, and no plugin channel is needed.
    svc.bindStoreForTest(AccountStore.fallback(disk));
  });

  tearDown(() => svc.resetForTest());

  group('CloudConfigService disk cache', () {
    test('fresh config cache: load() serves it with zero network calls',
        () async {
      disk[_kConfigs] = jsonEncode(<String, String>{
        'filing_number': 'Test-Filing-001',
        'privacy_policy_url': 'https://example.test/privacy',
      });
      disk[_kConfigsAt] = nowMs().toString();

      final ok = await _offline(() => svc.load(), requests);
      expect(ok, isTrue);
      expect(requests, isEmpty, reason: 'valid cache must not trigger HTTP');
      expect(svc.loaded, isTrue);
      expect(svc.filingNumber, 'Test-Filing-001');
      expect(svc.privacyPolicyUrl, 'https://example.test/privacy');
      // Missing keys still fall back to the built-in constants.
      expect(svc.feedbackEmail, LegalConstants.feedbackEmail);
    });

    test('fresh doc cache: fetchDoc() serves it with zero network calls',
        () async {
      disk[_kPolicyDoc] = '# cached privacy policy';
      disk[_kPolicyDocAt] = nowMs().toString();

      final content =
          await _offline(() => svc.fetchDoc('privacy_policy'), requests);
      expect(content, '# cached privacy policy');
      expect(requests, isEmpty, reason: 'valid doc cache must not trigger HTTP');
    });

    test('stale config + unreachable backend keeps the last cached value',
        () async {
      disk[_kConfigs] = jsonEncode(<String, String>{
        'filing_number': 'Old-Filing-999',
      });
      disk[_kConfigsAt] =
          (nowMs() - CloudConfigService.cacheTtl.inMilliseconds - 1000)
              .toString();

      final ok = await _offline(() => svc.load(), requests);
      expect(requests, hasLength(1), reason: 'TTL expired -> one revalidation');
      expect(ok, isTrue, reason: 'old cache still counts as usable config');
      expect(svc.filingNumber, 'Old-Filing-999');
    });

    test('stale doc + unreachable backend returns old text instead of null',
        () async {
      disk[_kPolicyDoc] = '# stale but usable policy';
      disk[_kPolicyDocAt] =
          (nowMs() - CloudConfigService.cacheTtl.inMilliseconds - 1000)
              .toString();

      final content =
          await _offline(() => svc.fetchDoc('privacy_policy'), requests);
      expect(requests, hasLength(1));
      expect(content, '# stale but usable policy');
    });

    test('no cache + unreachable backend degrades to built-in constants',
        () async {
      final ok = await _offline(() => svc.load(), requests);
      expect(ok, isFalse);
      expect(svc.filingNumber, LegalConstants.filingNumber);
      expect(svc.privacyPolicyUrl, LegalConstants.privacyPolicyUrl);
      requests.clear();
      final content =
          await _offline(() => svc.fetchDoc('privacy_policy'), requests);
      expect(content, isNull);
    });

    test('corrupt cache JSON is ignored, never crashes', () async {
      disk[_kConfigs] = 'this-is-not-json';
      disk[_kConfigsAt] = nowMs().toString();

      final ok = await _offline(() => svc.load(), requests);
      expect(ok, isFalse);
      expect(svc.filingNumber, LegalConstants.filingNumber);
    });

    test('isStale() TTL boundaries', () {
      const ttl = Duration(hours: 24);
      expect(CloudConfigService.isStale(0, ttl), isTrue,
          reason: 'never checked -> must revalidate');
      expect(CloudConfigService.isStale(nowMs(), ttl), isFalse);
      expect(CloudConfigService.isStale(nowMs() - ttl.inMilliseconds + 1000, ttl),
          isFalse);
      expect(
          CloudConfigService.isStale(
              nowMs() - ttl.inMilliseconds - 1000, ttl),
          isTrue);
    });

    test('force: true bypasses a fresh cache', () async {
      disk[_kConfigs] = jsonEncode(<String, String>{
        'filing_number': 'Fresh-But-Forced',
      });
      disk[_kConfigsAt] = nowMs().toString();

      final ok = await _offline(() => svc.load(force: true), requests);
      expect(requests, hasLength(1));
      expect(ok, isTrue);
      expect(svc.filingNumber, 'Fresh-But-Forced');
    });
  });
}
