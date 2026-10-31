import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Ad-delivery seam. Platform implementations slot in behind [createAdPal]:
///   Android -> google_mobile_ads (AdMob)
///   OHOS    -> HUAWEI Ads / Petals Ads (pending HMS signing + ad-slot IDs)
///
/// Until the OHOS native integration lands, [NoOpAdPal] keeps the app ad-free
/// and crash-free (matches the project's safe-default philosophy in OhosPal).
abstract interface class AdPal {
  /// Show an interstitial ad. Returns true if one was actually shown.
  Future<bool> showInterstitial();

  /// Returns a banner widget to embed in the UI, or null if unsupported
  /// (e.g. OHOS before Huawei Ads is wired, or an ad-free user).
  Widget? bannerWidget();
}

class NoOpAdPal implements AdPal {
  @override
  Future<bool> showInterstitial() async => false;

  @override
  Widget? bannerWidget() => null;
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
  Widget? bannerWidget() => const _AdBannerWidget();
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
