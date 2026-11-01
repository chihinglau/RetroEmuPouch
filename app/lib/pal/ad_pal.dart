import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Ad-delivery seam. Platform implementations slot in behind [createAdPal]:
///   Android -> google_mobile_ads (AdMob)
///   OHOS    -> HUAWEI Ads / Petals Ads (pending HMS signing + ad-slot IDs)
///
/// Until the OHOS native integration lands, [NoOpAdPal] keeps the app
/// crash-free (matches the project's safe-default philosophy in OhosPal) and
/// renders a **visible test-placement placeholder** banner so the library
/// layout/placement can be validated on-device without a real ad SDK.
abstract interface class AdPal {
  /// Show an interstitial ad. Returns true if one was actually shown.
  Future<bool> showInterstitial();

  /// Returns a banner widget to embed in the UI. On Android this is a real
  /// AdMob banner; on OHOS (pre-Huawei-Ads) it's a test-placement placeholder,
  /// so it is never null while the platform is wired enough to show one.
  Widget bannerWidget();
}

class NoOpAdPal implements AdPal {
  @override
  Future<bool> showInterstitial() async => false;

  @override
  Widget bannerWidget() => const _OhosTestBannerWidget();
}

/// Mock banner shown on OHOS until HUAWEI/Petals Ads is wired. It is NOT a
/// real ad — just a clearly-labeled placeholder so the library bottom placement
/// is visible and testable. height ~50px mirrors an AdMob banner slot.
class _OhosTestBannerWidget extends StatelessWidget {
  const _OhosTestBannerWidget();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    return Container(
      height: 50,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(Icons.ad_units_outlined, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '测试广告位（OHOS 占位，未接华为 / Petals 广告）',
              style: theme.textTheme.labelSmall?.copyWith(color: fg),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('广告',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: fg, fontSize: 10)),
          ),
        ],
      ),
    );
  }
}

/// Real AdMob implementation for Android. Uses Google's **test** ad unit IDs by
/// default so the flow is debuggable without a published app; swap the two
/// constants for real values from the AdMob console before release.
class GoogleMobileAdsAdPal implements AdPal {
  GoogleMobileAdsAdPal();

  // --- Swap these for real IDs from the AdMob console before release. ---
  static const interstitialAdUnitId = 'ca-app-pub-3940256099942544/1033173712';
  static const bannerAdUnitId = 'ca-app-pub-3940256099942544/6300978111';

  static Future<void>? _initFuture;

  /// Idempotent SDK init (no-op on repeated calls).
  static Future<void> ensureInitialized() {
    _initFuture ??= MobileAds.instance.initialize();
    return _initFuture!;
  }

  @override
  Future<bool> showInterstitial() async {
    await ensureInitialized();
    final shown = Completer<bool>();
    await InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (a) {
              a.dispose();
              if (!shown.isCompleted) shown.complete(true);
            },
            onAdFailedToShowFullScreenContent: (a, _) {
              a.dispose();
              if (!shown.isCompleted) shown.complete(false);
            },
          );
          ad.show();
        },
        onAdFailedToLoad: (_) {
          if (!shown.isCompleted) shown.complete(false);
        },
      ),
    );
    return shown.future;
  }

  @override
  Widget bannerWidget() => const _AdBannerWidget();
}

/// Self-loading AdMob banner. Only ever instantiated on Android (the OHOS
/// [NoOpAdPal] returns null from [GoogleMobileAdsAdPal.bannerWidget] is never
/// reached), but it compiles everywhere since it only touches
/// [google_mobile_ads] types.
class _AdBannerWidget extends StatefulWidget {
  const _AdBannerWidget();

  @override
  State<_AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<_AdBannerWidget> {
  BannerAd? _ad;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await GoogleMobileAdsAdPal.ensureInitialized();
    final ad = BannerAd(
      adUnitId: GoogleMobileAdsAdPal.bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => setState(() {}),
        onAdFailedToLoad: (_, error) => setState(() {}),
      ),
    );
    await ad.load();
    if (mounted) {
      _ad = ad;
      setState(() {});
    } else {
      ad.dispose();
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    return SizedBox(
      height: ad.size.height.toDouble(),
      width: ad.size.width.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}

/// Returns the platform-appropriate [AdPal]. Android uses real AdMob; OHOS
/// stays [NoOpAdPal] until HUAWEI/Petals Ads is wired (needs HMS signing +
/// ad-slot IDs — see design doc).
AdPal createAdPal() {
  if (Platform.operatingSystem == 'android') return GoogleMobileAdsAdPal();
  return NoOpAdPal();
}
