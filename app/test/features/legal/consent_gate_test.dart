import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/legal/consent_policy.dart';

// Regression cover for 2026-11-05: the old gate was shown on EVERY cold
// start because its "skip" branch was dead code (effectiveBaseUrl() never
// returns an empty string), and it re-POSTed consent/accept each launch.
// The decision logic now lives in consent_policy.dart as pure functions.
void main() {
  ConsentDocVersion doc({
    String key = 'privacy_policy',
    int latest = 2,
    int? mine,
    bool need = true,
  }) =>
      ConsentDocVersion(
        docKey: key,
        latestPublishedVersion: latest,
        myConsentedVersion: mine,
        needsReconsent: need,
      );

  group('hasPriorConsent / decideConsentGate', () {
    test('first install: no versions, no legacy flag -> show gate', () {
      expect(hasPriorConsent(<String, int>{}, false), isFalse);
      expect(
        decideConsentGate(hasPriorConsent: false, reconsentPending: false),
        ConsentGateDecision.showGate,
      );
    });

    test('already consented -> straight into the app', () {
      expect(hasPriorConsent(<String, int>{'privacy_policy': 1}, false), isTrue);
      expect(
        decideConsentGate(hasPriorConsent: true, reconsentPending: false),
        ConsentGateDecision.enterApp,
      );
    });

    test('legacy consent_given flag is enough (upgrade path)', () {
      expect(hasPriorConsent(<String, int>{}, true), isTrue);
      expect(
        decideConsentGate(hasPriorConsent: true, reconsentPending: false),
        ConsentGateDecision.enterApp,
      );
    });

    test('version bump pending -> gate is shown again', () {
      expect(
        decideConsentGate(hasPriorConsent: true, reconsentPending: true),
        ConsentGateDecision.showGate,
      );
    });
  });

  group('shouldRecheckConsent (24h silent check)', () {
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    const ttl = Duration(hours: 24);

    test('never checked / garbage value -> recheck', () {
      expect(shouldRecheckConsent(0, now, interval: ttl), isTrue);
      expect(shouldRecheckConsent(-1, now, interval: ttl), isTrue);
    });

    test('just checked -> no recheck', () {
      expect(
          shouldRecheckConsent(now.millisecondsSinceEpoch, now, interval: ttl),
          isFalse);
      expect(
          shouldRecheckConsent(
              now.millisecondsSinceEpoch - ttl.inMilliseconds + 1,
              now,
              interval: ttl),
          isFalse);
    });

    test('TTL boundary -> recheck', () {
      expect(
          shouldRecheckConsent(
              now.millisecondsSinceEpoch - ttl.inMilliseconds,
              now,
              interval: ttl),
          isTrue);
    });
  });

  group('needsReconsentForDoc', () {
    test('locally accepted the current version -> skip even if backend says yes',
        () {
      expect(
          needsReconsentForDoc(doc(latest: 2, need: true),
              <String, int>{'privacy_policy': 2}),
          isFalse);
      expect(
          needsReconsentForDoc(doc(latest: 2, need: true),
              <String, int>{'privacy_policy': 3}),
          isFalse);
    });

    test('older local version + needs_reconsent -> ask again', () {
      expect(
          needsReconsentForDoc(doc(latest: 2, mine: 1),
              <String, int>{'privacy_policy': 1}),
          isTrue);
    });

    test('backend reports no reconsent and versions match -> no gate', () {
      expect(
          needsReconsentForDoc(doc(latest: 2, mine: 2, need: false),
              <String, int>{}),
          isFalse);
    });

    test('backend version ahead of my consented version -> ask again', () {
      expect(
          needsReconsentForDoc(doc(latest: 3, mine: 2, need: false),
              <String, int>{}),
          isTrue);
    });

    test('docsNeedingReconsent filters a mixed status list', () {
      final need = docsNeedingReconsent(
        <ConsentDocVersion>[
          doc(key: 'privacy_policy', latest: 2, need: true),
          doc(key: 'eula', latest: 1, mine: 1, need: false),
          doc(key: 'missing', latest: 5, need: true),
        ],
        <String, int>{'privacy_policy': 2},
      );
      expect(need.map((d) => d.docKey), <String>['missing']);
    });
  });

  group('parseConsentVersions', () {
    test('valid JSON map', () {
      expect(
        parseConsentVersions('{"privacy_policy":2,"eula":1}'),
        <String, int>{'privacy_policy': 2, 'eula': 1},
      );
    });

    test('null / empty / corrupt / non-map fall back to legacy keys', () {
      expect(parseConsentVersions(null), isNull);
      expect(parseConsentVersions(''), isNull);
      expect(parseConsentVersions('not-json'), isNull);
      expect(parseConsentVersions('[1,2]'), isNull);
    });
  });

  group('ConsentDocVersion serialisation', () {
    test('toJson / fromJson round-trip', () {
      final d = doc(latest: 7, mine: 6, need: true);
      final restored = ConsentDocVersion.fromJson(d.toJson());
      expect(restored, isNotNull);
      expect(restored!.docKey, 'privacy_policy');
      expect(restored.latestPublishedVersion, 7);
      expect(restored.myConsentedVersion, 6);
      expect(restored.needsReconsent, isTrue);
    });

    test('malformed entries are dropped', () {
      expect(ConsentDocVersion.fromJson(null), isNull);
      expect(ConsentDocVersion.fromJson(<String, dynamic>{}), isNull);
      expect(ConsentDocVersion.fromJson(<String, dynamic>{'doc_key': 'x'})!
          .latestPublishedVersion, 1);
    });
  });
}
