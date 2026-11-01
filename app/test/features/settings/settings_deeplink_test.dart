import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/settings/settings_sheet.dart';
import 'package:retroemupouch/pal/platform_pal.dart';

/// 与「网络」页「会员服务」按钮行为一致：调用 SettingsSheet.show 并传入
/// deepLink='membership'，打开设置页后应自动跳转到「会员 / 去广告」子页。
void main() {
  testWidgets('deepLink=membership 自动打开 会员/去广告 子页',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => GestureDetector(
            onTap: () =>
                SettingsSheet.show(ctx, pal: _FakePal(), deepLink: 'membership'),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    // 显式推进若干帧：打开底部弹窗 + post-frame 回调深链推送会员子页，
    // 不用 pumpAndSettle（会员页加载态可能有持续 ticker）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));

    // 会员 / 去广告 子页的 AppBar 标题应存在（不论 Membership 是否加载成功）。
    expect(find.text('会员 / 去广告'), findsWidgets);
  });
}

/// 仅用于测试的最小 PlatformPal 桩：implements 抽象接口需实现全部成员
/// （含带默认实现体的方法）。
class _FakePal implements PlatformPal {
  @override
  Stream<NetplayPlayEnd> get netplayPlayEnds => const Stream.empty();
  @override
  Future<void> stopNetplay() async {}
  @override
  bool get emulatorCoversFlutter => false;
  @override
  Future<String> filesDir() async => '.';
  @override
  Future<String?> deviceModel() async => null;
  @override
  Future<int?> availableBytes() async => null;
  @override
  Future<bool> acquireMulticastLock() async => false;
  @override
  Future<bool> releaseMulticastLock() async => false;
  @override
  Future<String?> runningSaveKey() async => null;
  @override
  Future<ImportedRom?> importRomViaSaf({String mime = '*/*'}) async => null;
  @override
  Future<String?> importBiosViaSaf() async => null;
  @override
  Future<List<String>> importBiosBatchViaSaf() async => const [];
  @override
  Future<bool?> exportBiosZipViaSaf() async => null;
  @override
  Future<bool> deleteBios(String name) async => false;
  @override
  Future<ImportedPackage?> importPackageViaSaf() async => null;
  @override
  Future<bool> exportPackageViaSaf(
          {required String sourcePath, required String suggestedName}) async =>
      false;
  @override
  Future<ImportedMovesConfig?> importMovesConfigViaSaf() async => null;
  @override
  Future<bool> exportMovesConfigViaSaf(
          {required String sourcePath, required String suggestedName}) async =>
      false;
  @override
  Future<ImportedPadConfig?> importPadConfigViaSaf() async => null;
  @override
  Future<bool> exportPadConfigViaSaf(
          {required String sourcePath, required String suggestedName}) async =>
      false;
  @override
  Future<bool> launchEmulator(
          {required String relativePath,
          required String coreId,
          required String platform,
          Map<String, dynamic>? netplay}) async =>
      false;
  @override
  Future<AppVersion> appVersion() async =>
      AppVersion(versionCode: 1, versionName: '1.0');
  @override
  Future<Map<String, Object>?> loadAppSettings() async => null;
  @override
  Future<void> saveAppSettings(Map<String, Object> data) async {}
  @override
  Future<Map<String, Object>?> loadKeyValueStore(String name) async => null;
  @override
  Future<void> saveKeyValueStore(String name, Map<String, Object> data) async {}
  @override
  Future<bool> installApk(String absolutePath) async => false;
  @override
  Future<void> openStore() async {}
}
