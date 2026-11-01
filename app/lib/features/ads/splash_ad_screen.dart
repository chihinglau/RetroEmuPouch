import 'dart:async';

import 'package:flutter/material.dart';

import '../../pal/ad_pal.dart';
import '../../pal/platform_pal.dart';
import '../library/library_page.dart';

/// 开屏广告测试占位页：约 5 秒倒计时，右上角「跳过」可立即进入主界面。
///
/// 仅在 OHOS（`NoOpAdPal`，华为 / Petals 广告尚未接入）作为**测试占位**显示，
/// 用于验证开屏广告的布局与跳转。真实广告接入后由对应 [AdPal] 的 open-ad
/// 实现取代（见 [shouldShowSplashTestAd]），本页不参与真实投放。
class SplashAdScreen extends StatefulWidget {
  const SplashAdScreen({super.key, required this.pal});
  final PlatformPal pal;

  @override
  State<SplashAdScreen> createState() => _SplashAdScreenState();
}

class _SplashAdScreenState extends State<SplashAdScreen> {
  static const _seconds = 5;
  int _remaining = _seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (--_remaining <= 0) {
        t.cancel();
        _go();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => LibraryPage(pal: widget.pal)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final sub = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.primaryContainer,
                  theme.colorScheme.surface,
                ],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.ad_units_outlined,
                      size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('测试开屏广告',
                      style: theme.textTheme.headlineSmall?.copyWith(color: fg)),
                  const SizedBox(height: 8),
                  Text('（OHOS 占位，未接华为 / Petals 广告）',
                      style: theme.textTheme.bodySmall?.copyWith(color: sub)),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      value: (_seconds - _remaining) / _seconds,
                      strokeWidth: 4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            right: 12,
            child: TextButton(
              onPressed: _go,
              child: Text('跳过 $_remaining'),
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('广告',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: sub, fontSize: 10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 是否显示开屏广告测试占位：OHOS（`NoOpAdPal`，华为 / Petals 广告未接入）显示；
/// 真实广告平台由对应 [AdPal] 的 open-ad 实现处理（后续接入后本函数返回 false）。
bool shouldShowSplashTestAd() => createAdPal() is NoOpAdPal;
