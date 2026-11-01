import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:retroemupouch/features/legal/legal_constants.dart';
import 'package:retroemupouch/features/membership/entitlement_service.dart';
import 'package:retroemupouch/features/membership/membership.dart';

import '../../main.dart';
import '../../features/legal/privacy_policy_page.dart';
import '../../pal/platform_pal.dart';
import '../../system_files.dart';
import 'app_settings.dart';
import 'special_moves_editor.dart';

/// Modal bottom sheet that combines the app's "About" content (name +
/// version + open-source licence info) and runtime configuration options
/// (FPS overlay, refresh rate, etc.) into a single place reachable from
/// the library AppBar.
///
/// Configurable settings are loaded on open and saved on every toggle
/// change, so closing the sheet (or the app) never loses work.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet(
      {super.key,
      required this.hostCtx,
      required this.pal,
      this.deepLink});

  /// [deepLink] 非空时，设置页打开后自动跳转到对应子页（如 'membership'
  /// 直达「会员 / 去广告」），用于从「网络」页等位置深链进入。
  static Future<void> show(BuildContext context,
      {required PlatformPal pal, String? deepLink}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) =>
          SettingsSheet(hostCtx: context, pal: pal, deepLink: deepLink),
    );
  }

  /// Outer context (the page that opened the sheet) — needed so we can
  /// reach the parent [GamePouchApp] for live theme updates without
  /// requiring the settings sheet itself to rebuild the whole app.
  final BuildContext hostCtx;

  /// Used to read the real installed version for the App-info card.
  final PlatformPal pal;

  /// 深链目标：'membership' 打开后直达「会员 / 去广告」子页。
  final String? deepLink;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late AppSettings _settings;
  late final BuildContext _ctx;
  AppVersion? _version;

  /// Notifies pushed settings sub-pages (outside this State's element tree)
  /// that a setting changed — [setState] only rebuilds the menu sheet itself.
  final _SettingsNotifier _changes = _SettingsNotifier();

  @override
  void initState() {
    super.initState();
    _ctx = widget.hostCtx;
    _settings = AppSettings.current;
    widget.pal.appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
    if (widget.deepLink == 'membership') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openMembership();
      });
    }
  }

  @override
  void dispose() {
    _changes.dispose();
    super.dispose();
  }

  void _patch(void Function(AppSettings s) mutator) {
    final before = _settings.clone();
    setState(() => mutator(_settings));
    // Fire-and-forget — saves are tiny and SharedPreferences handles
    // concurrent writes internally.
    _settings.save();
    // Side effects that need to happen synchronously alongside the
    // toggle so the change is visible without an app restart.
    _applySideEffects(before, _settings);
    _changes.ping();
  }

  /// Reflect a setting change in the running app without restarting.
  ///
  ///  - Toggling `rememberLastGame` off clears the `lastSaveSlot`
  ///    pointer so the next emulator entry won't auto-load.
  ///  - Toggling `darkTheme` flips the app theme live via the
  /// [GamePouchApp]'s shared key.
  Future<void> _applySideEffects(
      AppSettings before, AppSettings after) async {
    // Resolve the app state *before* awaiting: touching a BuildContext across
    // an async gap is unsafe (the widget may have been disposed).
    final app = GamePouchApp.of(_ctx);
    if (before.rememberLastGame && !after.rememberLastGame) {
      await AppSettings.clearLastSaveSlot();
    }
    if (before.darkTheme != after.darkTheme) {
      app?.setBrightness(after.darkTheme);
    }
  }

  Future<void> _showLicenses() async {
    final text = await rootBundle.loadString('assets/OSS_LICENSES.md');
    if (!mounted || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开源许可'),
        scrollable: true,
        content: SelectableText(
          text,
          style: Theme.of(ctx)
              .textTheme
              .bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                  child: Row(
                    children: [
                      Icon(Icons.videogame_asset_outlined,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('设置', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _version == null
                              ? '加载中…'
                              : '${_version!.versionName} (${_version!.versionCode})',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ----- 分类主菜单：一行一个子页面（iOS 风格彩色入口） -----
                _MenuRow(
                  icon: Icons.menu_book_outlined,
                  iconColor: const Color(0xFF3E7BFA),
                  title: '使用教程',
                  subtitle: '了解如何导入和使用游戏',
                  onTap: _openTutorial,
                ),
                _MenuRow(
                  icon: Icons.workspace_premium_outlined,
                  iconColor: const Color(0xFFB45CF6),
                  title: '会员 / 去广告',
                  subtitle: '成为 VIP，享受纯净体验 · 管理订阅',
                  onTap: _openMembership,
                ),
                _MenuRow(
                  icon: Icons.share_outlined,
                  iconColor: const Color(0xFF22B8A6),
                  title: '分享应用',
                  subtitle: '推荐给朋友',
                  onTap: () => _copyToClipboard(
                      LegalConstants.shareMessage, '推荐文案已复制，去粘贴给朋友吧'),
                ),
                _MenuRow(
                  icon: Icons.star_outline,
                  iconColor: const Color(0xFFF5A623),
                  title: '给个好评',
                  subtitle: '您的支持是我们前进的动力',
                  onTap: _openStoreReview,
                ),
                _MenuRow(
                  icon: Icons.mail_outline,
                  iconColor: const Color(0xFF4CAF50),
                  title: '意见反馈',
                  subtitle: '应用商店 · 邮件 · QQ群 · 微信',
                  onTap: _openFeedback,
                ),
                _MenuRow(
                  icon: Icons.tune_outlined,
                  iconColor: const Color(0xFF5C6BC0),
                  title: '个性化设置',
                  subtitle: '游戏体验 · 控制与手柄 · BIOS · 通用',
                  onTap: _openPersonalization,
                ),
                _MenuRow(
                  icon: Icons.info_outline,
                  iconColor: const Color(0xFFEC6B9D),
                  title: '关于与支持',
                  subtitle: '版本 · 许可 · 隐私 · 客服',
                  onTap: _openAbout,
                ),
                _MenuRow(
                  icon: Icons.restart_alt_outlined,
                  iconColor: const Color(0xFFE57373),
                  title: '还原设置',
                  subtitle: '还原模拟器默认设置，不会删除存档',
                  onTap: _confirmReset,
                ),

                const SizedBox(height: 12),
                Center(
                  child: Text(
                    '趣玩匣 RetroEmuPouch · 重拾时光里的欢喜',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 分类菜单的导航与公共动作
  // ------------------------------------------------------------------

  /// Pushes a full-screen settings sub-page on the *host* navigator (the
  /// sheet's own context would pop the route together with the sheet).
  void _push(WidgetBuilder builder) {
    Navigator.of(widget.hostCtx).push(
      MaterialPageRoute<void>(builder: builder),
    );
  }

  /// Rebuilds a sub-page body whenever a setting changes. A pushed route is
  /// outside this State's element tree, so [setState] alone can't refresh it —
  /// [_patch] fires [_changes] which these builders listen to.
  Widget _live(Widget Function(BuildContext) builder) {
    return ListenableBuilder(
      listenable: _changes,
      builder: (ctx, _) => builder(ctx),
    );
  }

  Widget _page(String title, List<Widget> children) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: children,
      ),
    );
  }

  Future<void> _copyToClipboard(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openStoreReview() async {
    try {
      await widget.pal.openStore();
    } catch (_) {
      await _copyToClipboard(
          LegalConstants.feedbackUrl, '未找到应用商店入口，已复制反馈链接');
    }
  }

  // ----- 子页面 -----

  void _openTutorial() =>
      _push((_) => _page('使用教程', const [_TutorialBody()]));

  void _openMembership() =>
      _push((_) => _page('会员 / 去广告', const [_MembershipPageBody()]));

  void _openFeedback() => _push(
      (_) => _page('意见反馈', [_FeedbackPageBody(pal: widget.pal)]));

  /// 「个性化设置」合并页：把原先分散的 游戏体验 / 控制与手柄 / BIOS / 通用
  /// 四个入口收进同一页，用分区标题区分，主菜单只留一个入口，更简洁。
  void _openPersonalization() => _push((_) => _page('个性化设置', [
        const _SectionTitle('游戏体验'),
        _live((_) => Column(children: [
              _SettingTile(
                icon: Icons.speed_outlined,
                title: '显示 FPS / xruns 浮窗',
                subtitle: '在游戏画面正中央叠加性能指示器',
                value: _settings.showFpsHud,
                onChanged: (v) => _patch((s) => s.showFpsHud = v),
              ),
              _SettingTile(
                icon: Icons.refresh_outlined,
                title: '高刷新率（120 Hz）',
                subtitle: '支持时优先使用最高刷新率以降低拖影',
                value: _settings.highRefreshRate,
                onChanged: (v) => _patch((s) => s.highRefreshRate = v),
              ),
              _SettingTile(
                icon: Icons.fast_forward_outlined,
                title: '加速时同步音频',
                subtitle: '关闭后加速时静音，换取更稳定的帧率',
                value: _settings.fastForwardAudio,
                onChanged: (v) => _patch((s) => s.fastForwardAudio = v),
              ),
            ])),
        const SizedBox(height: 12),
        const _SectionTitle('控制与手柄'),
        _live((_) => Column(children: [
              _StickSettingsCard(
                mode: _settings.stickMode,
                deadzone: _settings.stickDeadzone,
                useDpadUi: _settings.useDpadUi,
                onModeChanged: (m) => _patch((s) => s.stickMode = m),
                onDeadzoneChanged: (d) => _patch((s) => s.stickDeadzone = d),
                onUseDpadUiChanged: (v) => _patch((s) => s.useDpadUi = v),
              ),
              const SizedBox(height: 4),
              _PadLayoutCard(
                settings: _settings,
                pal: widget.pal,
                patch: _patch,
              ),
            ])),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('招式按键（格斗游戏一键大招）'),
            subtitle: const Text(
                '配置 6 个槽位的招式脚本，支持导入 / 导出，方便按游戏加载'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final filesDir = await widget.pal.filesDir();
              if (!widget.hostCtx.mounted) return;
              // Push via the host context so the editor lands on the
              // underlying navigator (the settings sheet's own context
              // pops with the sheet and would discard the route).
              Navigator.of(widget.hostCtx).push(
                MaterialPageRoute<void>(
                  builder: (_) => SpecialMovesEditorPage(
                    filesDir: filesDir,
                    pal: widget.pal,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        const _SectionTitle('系统文件（BIOS）'),
        _BiosManagerCard(pal: widget.pal),
        const SizedBox(height: 12),
        const _SectionTitle('通用'),
        _live((_) => Column(children: [
              _SettingTile(
                icon: Icons.history_outlined,
                title: '记住上次进度',
                subtitle: '启动时自动恢复上次运行的进度',
                value: _settings.rememberLastGame,
                onChanged: (v) => _patch((s) => s.rememberLastGame = v),
              ),
              _SettingTile(
                icon: Icons.dark_mode_outlined,
                title: '深色主题',
                subtitle: '深色 Material 配色，省电且夜间友好',
                value: _settings.darkTheme,
                onChanged: (v) => _patch((s) => s.darkTheme = v),
              ),
            ])),
      ]));

  void _openAbout() => _push((ctx) {
        final theme = Theme.of(ctx);
        return _page('关于与支持', [
          // ----- App info（原「关于」内容，从主菜单移入） -----
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.videogame_asset_outlined,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('趣玩匣 RetroEmuPouch',
                          style: theme.textTheme.titleMedium),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _version == null
                              ? '加载中…'
                              : '${_version!.versionName} (${_version!.versionCode})',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '本应用不内置任何游戏 ROM 或 BIOS，请自行导入合法备份。',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '模拟核心：FCEUmm / Gambatte / mGBA / PicoDrive / '
                    'Stella（libretro），GPL-2.0 / MPL-2.0。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('客服中心'),
              subtitle: const Text('问题反馈与联系支持（复制反馈入口）'),
              trailing: const Icon(Icons.copy_outlined),
              onTap: () => _copyToClipboard(
                  LegalConstants.feedbackUrl, '反馈链接已复制，可在浏览器打开'),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('开源许可'),
              subtitle: const Text('内嵌模拟器核心的许可证与源码出处'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showLicenses,
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('隐私政策 / 用户协议'),
              subtitle: const Text('我们如何收集、使用与保护您的数据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(widget.hostCtx).push(
                MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.language_outlined),
              title: const Text('网页版隐私政策'),
              subtitle: const Text(
                  'https://chihinglau.github.io/GamePouch/privacy'),
              trailing: const Icon(Icons.copy_outlined),
              onTap: () => _copyToClipboard(
                  LegalConstants.privacyPolicyUrl, '已复制隐私政策链接，可在浏览器打开'),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('备案号'),
              subtitle: Text(
                LegalConstants.filingNumber.isEmpty
                    ? '（备案中，待工信部备案后回填）'
                    : LegalConstants.filingNumber,
              ),
            ),
          ),
        ]);
      });

  /// 还原设置：确认后把全部 AppSettings 字段重置为出厂默认（不触碰存档/BIOS）。
  Future<void> _confirmReset() async {
    // Resolve the app state *before* awaiting: touching a BuildContext across
    // an async gap is unsafe (the widget may have been disposed).
    final app = GamePouchApp.of(_ctx);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还原设置'),
        content: const Text('将全部设置恢复为默认值（画面 / 控制 / 手柄布局等）。\n\n'
            '不会删除游戏、存档与 BIOS。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('还原'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final before = _settings.clone();
    setState(() => _settings.applyMap(AppSettings().toMap()));
    await _settings.save();
    if (before.darkTheme != _settings.darkTheme) {
      app?.setBrightness(_settings.darkTheme);
    }
    _changes.ping();
    if (!mounted || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已还原为默认设置')));
  }
}

/// 用于把设置变更广播给推送出去的子页面（封装 protected 的 notifyListeners）。
class _SettingsNotifier extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// 分类主菜单的一行：彩色圆角底 + 图标 + 标题/副标题 + 右箭头（iOS 设置风格）。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: iconColor.withAlpha(31),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: theme.hintColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「意见反馈」子页面正文：多渠道选择（参照 iOS 反馈弹窗风格）。
/// 零依赖实现：应用商店走 `PlatformPal.openStore()`；邮件 / QQ群 / 微信复制
/// 账号到剪贴板（无 url_launcher / share 插件），发布时替换 `LegalConstants`。
class _FeedbackPageBody extends StatelessWidget {
  const _FeedbackPageBody({required this.pal});

  final PlatformPal pal;

  Future<void> _copy(BuildContext context, String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 不用 stretch（同 _MembershipPageBody：OHOS fork 上零高布局 bug）。
    return Column(
      children: [
        Text('感谢您的支持！选择反馈方式：', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        _FeedbackChannelButton(
          label: '跳转应用商店',
          onTap: () async {
            var failed = false;
            try {
              await pal.openStore();
            } catch (_) {
              failed = true;
            }
            if (!failed || !context.mounted) return;
            await _copy(context, LegalConstants.feedbackUrl,
                '未找到应用商店入口，已复制反馈链接');
          },
        ),
        _FeedbackChannelButton(
          label: '发送邮件',
          onTap: () =>
              _copy(context, LegalConstants.feedbackEmail, '邮箱已复制，可在邮件 App 粘贴发送'),
        ),
        _FeedbackChannelButton(
          label: 'QQ群反馈',
          onTap: () => _copy(
              context, LegalConstants.qqGroup, 'QQ群号已复制，可在 QQ 中搜索加群'),
        ),
        _FeedbackChannelButton(
          label: '微信反馈',
          onTap: () => _copy(
              context, LegalConstants.wechatId, '微信号已复制，可在微信中搜索添加'),
        ),
      ],
    );
  }
}

/// 反馈渠道大按钮：全宽圆角胶囊、浅灰底、居中加粗文字。
class _FeedbackChannelButton extends StatelessWidget {
  const _FeedbackChannelButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Center(
              child: Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 会员计费档位卡（超级 / 普通 VIP 共用布局）。
class _Plan {
  const _Plan(this.price, this.period, this.hint, {this.trial = true});
  final String price;
  final String period;
  final String hint;
  final bool trial;
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.plans,
    required this.onPlanTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final List<_Plan> plans;
  final void Function(_Plan plan, int index) onPlanTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 8),
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withAlpha(38),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('免费试用',
                    style: theme.textTheme.labelSmall?.copyWith(color: color)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(
            // 不要 crossAxisAlignment: stretch——本 Row 处于 ListView 无界高度
            // 上下文，stretch+Expanded 会触发 RenderFlex 断言，布局中断导致
            // 整页头部错位、后续档位卡不渲染。Expanded 子项默认取 Row 高度即可。
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < plans.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _PlanTile(plan: plans[i], color: color, onTap: () => onPlanTap(plans[i], i))),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.plan, required this.color, required this.onTap});

  final _Plan plan;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recommended = plan.hint == '最划算';
    final border = recommended ? Colors.green : theme.colorScheme.outlineVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(color: border, width: recommended ? 1.6 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(plan.price,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(plan.period,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 30,
            child: FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: plan.trial ? const Color(0xFFFF8A1E) : color,
                padding: EdgeInsets.zero,
                textStyle: theme.textTheme.labelMedium,
              ),
              child: Text(plan.trial ? '免费试用' : '购买'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「会员 / 去广告」子页面正文（参照 iOS 会员页结构）：
/// 头部致谢 + 当前状态 → 免费试用说明卡 → 超级 VIP / 普通 VIP 双档位。
/// 价格为展示值（真实价格以应用商店为准，接入计费后由商店拉取）。
class _MembershipPageBody extends StatefulWidget {
  const _MembershipPageBody();

  @override
  State<_MembershipPageBody> createState() => _MembershipPageBodyState();
}

class _MembershipPageBodyState extends State<_MembershipPageBody> {
  Membership? _m;
  bool _failed = false;
  StreamSubscription<Entitlement>? _sub;

  @override
  void initState() {
    super.initState();
    // catchError：Membership.instance 万一失败时给出明确提示，
    // 而不是永远停在加载条（OHOS shared_preferences 缺 handler 曾是根因）。
    Membership.instance.then((m) {
      if (!mounted) return;
      setState(() => _m = m);
      _sub = m.entitlement.changes.listen((_) {
        if (mounted) setState(() {});
      });
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「免费试用」按钮：从未试用过则开启试用，否则视为购买该档位。
  Future<void> _trialOrBuy(MembershipTier tier) async {
    final m = _m;
    if (m == null) return;
    if (m.entitlement.current.trialStart == null) {
      await m.entitlement.ensureTrialStarted();
      _toast('已开启 ${EntitlementService.trialDays} 天免费试用');
      return;
    }
    await _buy(tier);
  }

  Future<void> _buy(MembershipTier tier) async {
    final m = _m;
    if (m == null) return;
    final ok = await m.billing.buy(tier);
    _toast(ok ? '已开通（本地授予，真实计费待接入商店）' : '购买未完成');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _m;
    if (m == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: _failed
            ? Text('会员服务加载失败，请重启应用重试',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error))
            : const LinearProgressIndicator(),
      );
    }
    final e = m.entitlement;
    final tier = e.current.effectiveTier;
    final statusText = switch (tier) {
      MembershipTier.free => '免费用户',
      MembershipTier.trial =>
        '试用中 · 剩余 ${e.trialRemainingDays} 天',
      _ => '${tier.label}（已去广告）',
    };

    // 注意：不要用 crossAxisAlignment: stretch——OHOS fork 上 stretch Column
    // 直接子项（Text/Row）在 ListView 无界高度下会零高布局、全部叠在原点
    // （Container 包裹的子项正常）。ListView 本给满宽约束，去掉 stretch 等价。
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.favorite, color: Color(0xFFE91E63), size: 24),
            const SizedBox(width: 6),
            Text('支持开发者',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 6),
        Text('感谢您使用我们的应用！您的支持是我们持续改进的动力',
            textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text('当前状态：$statusText',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.primary)),
        const SizedBox(height: 14),

        // ----- 免费试用说明卡 -----
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFF8A1E), width: 1.2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.card_giftcard, color: Color(0xFFFF8A1E), size: 20),
                SizedBox(width: 6),
                Text('免费试用 ${EntitlementService.trialDays} 天',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 8),
              Text('· 试用期内去除所有广告、解锁云存档权益',
                  style: theme.textTheme.bodySmall),
              Text('· 到期后自动回到免费版，不会自动扣费',
                  style: theme.textTheme.bodySmall),
              Text('· 每个账号仅可试用一次，随时可购买正式档位',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ----- 超级 VIP（去所有广告 + 云存档）-----
        _TierCard(
          icon: Icons.diamond_outlined,
          color: const Color(0xFFB45CF6),
          title: '超级 VIP',
          description: '去除所有广告，完全离线，享受纯净体验（含云存档权益）',
          plans: const [
            _Plan('¥15.00', '/月', '按月订阅'),
            _Plan('¥22.00', '/年', '最划算'),
            _Plan('¥38.00', '(永久)', '一次买断', trial: false),
          ],
          onPlanTap: (plan, i) => plan.trial
              ? _trialOrBuy(i == 0
                  ? MembershipTier.monthly
                  : MembershipTier.yearly)
              : _buy(MembershipTier.lifetime),
        ),

        // ----- 普通 VIP（去开屏/视频广告，保留横幅）-----
        _TierCard(
          icon: Icons.star_outlined,
          color: const Color(0xFF2196F3),
          title: '普通 VIP',
          description: '去除开屏广告、视频广告，仅保留横幅广告，不影响游戏体验',
          plans: const [
            _Plan('¥8.00', '/月', '按月订阅'),
            _Plan('¥15.00', '/年', '最划算'),
            _Plan('¥18.00', '(永久)', '一次买断', trial: false),
          ],
          onPlanTap: (plan, i) => plan.trial
              ? _trialOrBuy(i == 0
                  ? MembershipTier.vipMonthly
                  : MembershipTier.vipYearly)
              : _buy(MembershipTier.vipLifetime),
        ),

        const Text(
          '订阅的查看、取消与更改可在应用商店的订阅管理中进行；'
          '价格与档位以后续接入的应用商店实际展示为准。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

/// 「使用教程」子页面正文：从导入到联机的入门步骤。
class _TutorialStep {
  const _TutorialStep(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

class _TutorialBody extends StatelessWidget {
  const _TutorialBody();

  static const _steps = <_TutorialStep>[
    _TutorialStep(Icons.download_outlined, '导入游戏',
        '在游戏库页点「导入」，选择 ROM 压缩包或单文件（支持 NES / GB / GBA / MD / 街机等），导入后自动识别平台。'),
    _TutorialStep(Icons.memory_outlined, '导入 BIOS',
        '部分平台（GBA / 街机等）需要系统 BIOS：设置 → BIOS 管理，导入对应文件（如 neogeo.zip、gba_bios）。'),
    _TutorialStep(Icons.play_circle_outline, '开始游戏',
        '点击库中的游戏即可运行；横竖屏与手柄布局可随时在「控制与手柄」中调整。'),
    _TutorialStep(Icons.bolt_outlined, '一键招式',
        '格斗游戏可在「控制与手柄 → 招式按键」配置一键大招（如 236+P），支持按游戏加载不同方案。'),
    _TutorialStep(Icons.cloud_sync_outlined, '同步与备份',
        '账号页可绑定「我的 PC」，在局域网内同步存档与设置；游戏资源也可打包导出分享。'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in _steps)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(s.icon, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.title, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(s.body, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// BIOS / system-file manager. Lists every BIOS the app knows about
/// (neogeo.zip / qsound.zip / …), shows installed vs missing, and lets the
/// user batch-import via SAF, export the lot as a single zip, or delete
/// an individual blob. The list reflects the on-disk state under
/// `<filesDir>/system/` plus the per-core subdir `system/mame/roms/`.
class _BiosManagerCard extends StatefulWidget {
  const _BiosManagerCard({required this.pal});
  final PlatformPal pal;

  @override
  State<_BiosManagerCard> createState() => _BiosManagerCardState();
}

class _BiosManagerCardState extends State<_BiosManagerCard> {
  /// All supported BIOS names (see `SystemFiles.supportedBios`). Mirrors the
  /// app-side registry so the list stays in lockstep with import validation,
  /// the peer `bios` API and the on-launch mirror step.
  List<String> get _knownBios =>
      List<String>.from(SystemFiles.biosNames())..sort();

  /// Names actually present under `<filesDir>/system/`. Reads the disk
  /// directly (no platform channel round-trip) — this UI opens on the
  /// settings sheet which already needs the file system to be available.
  Set<String> _present = <String>{};
  bool _busy = false;
  String? _msg;
  bool _msgIsError = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final sysPath = '${await widget.pal.filesDir()}/system';
    final present = <String>{};
    // Two source dirs are authoritative for "is this BIOS installed":
    //  1. `<filesDir>/system/` — where importBios writes the user-picked
    //     blobs. This is also the "Other" list (root-level files only).
    //  2. `<filesDir>/system/mame/roms/` — the per-core MAME subdir the
    //     `LockedRom` mirror step stages BIOS into on every launch.
    // The per-core subdir may also hold game ROMs the user pushed there
    // manually (it isn't a sanctioned "BIOS" location), so we only credit
    // it for the names in `SystemFiles.requiredBios` — never surface a
    // stray `1944.zip` as "other installed BIOS".
    final root = Directory(sysPath);
    if (root.existsSync()) {
      for (final f in root.listSync()) {
        if (f is File) present.add(f.uri.pathSegments.last.toLowerCase());
      }
    }
    final knownLower = _knownBios.map((n) => n.toLowerCase()).toSet();
    final mame = Directory('$sysPath/mame/roms');
    if (mame.existsSync()) {
      for (final f in mame.listSync()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last.toLowerCase();
        if (knownLower.contains(name)) present.add(name);
      }
    }
    if (!mounted) return;
    setState(() => _present = present);
  }

  void _setMsg(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _msg = text;
      _msgIsError = error;
    });
  }

  Future<void> _importBatch() async {
    setState(() => _busy = true);
    try {
      final names = await widget.pal.importBiosBatchViaSaf();
      // Mirror every newly imported blob into each per-core location.
      await SystemFiles.syncAll(widget.pal);
      await _refresh();
      if (names.isEmpty) {
        _setMsg('已取消');
      } else {
        _setMsg('已导入 ${names.length} 个文件：${names.join(', ')}');
      }
    } catch (e) {
      _setMsg('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportAll() async {
    setState(() => _busy = true);
    try {
      final ok = await widget.pal.exportBiosZipViaSaf();
      _setMsg(ok == true ? '已导出' : '已取消');
    } catch (e) {
      _setMsg('导出失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteOne(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $name？'),
        content: const Text(
            '该 BIOS 将从本机移除。再次游玩需要它的游戏前必须重新导入。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.pal.deleteBios(name);
      await _refresh();
      _setMsg('已删除 $name');
    } catch (e) {
      _setMsg('删除失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = _knownBios;
    final present = _present;
    final installed = known.where((n) => present.contains(n.toLowerCase())).toList();
    final missing = known.where((n) => !present.contains(n.toLowerCase())).toList();
    // Files the user dropped in that aren't in the known list (e.g. a
    // stray region BIOS). They still live under <system>/ so we surface
    // them with a "其他" tag so the user can manage them.
    final knownLower = known.map((n) => n.toLowerCase()).toSet();
    final others = present.where((n) => !knownLower.contains(n)).toList()..sort();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.developer_board_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('系统文件（BIOS）管理',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '本应用不内置任何 BIOS。请从你的合法备份中导入；'
              'MAME 街机需要 neogeo.zip（NeoGeo）、qsound.zip / qsound_hle.zip'
              '（Capcom CPS-1/2 Q-Sound）、pgm.zip（IGS PGM）等 BIOS。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            if (installed.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.check_circle_outline,
                color: Colors.green,
                text: '已安装（${installed.length}）',
              ),
              for (final n in installed) _BiosRow(
                name: n,
                installed: true,
                onDelete: _busy ? null : () => _deleteOne(n),
              ),
              const SizedBox(height: 8),
            ],
            if (missing.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.warning_amber_rounded,
                color: Colors.orange,
                text: '缺失（${missing.length}）',
              ),
              for (final n in missing)
                _BiosRow(name: n, installed: false, onDelete: null),
              const SizedBox(height: 8),
            ],
            if (others.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.folder_outlined,
                color: theme.colorScheme.onSurfaceVariant,
                text: '其他（${others.length}）',
              ),
              for (final n in others) _BiosRow(
                name: n,
                installed: true,
                onDelete: _busy ? null : () => _deleteOne(n),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _importBatch,
                    icon: const Icon(Icons.file_open),
                    label: const Text('批量导入'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _exportAll,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出全部'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_msg != null) ...[
              const SizedBox(height: 10),
              Text(
                _msg!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _msgIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BiosSectionHeader extends StatelessWidget {
  const _BiosSectionHeader({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 合并页内的分组标题（如「个性化设置」下区分 游戏体验 / 控制与手柄 等）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _BiosRow extends StatelessWidget {
  const _BiosRow({
    required this.name,
    required this.installed,
    required this.onDelete,
  });
  final String name;
  final bool installed;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check : Icons.error_outline,
            size: 16,
            color: installed ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// Virtual stick / d-pad configuration card. Three controls:
/// - **Mode** (STICK / DPAD8 / DPAD4): how the analog stick resolves to
///   digital d-pad bits.
/// - **Dead-zone** slider (0.0–0.45): fraction of the knob's travel below
///   which the stick reads as centred.
/// - **虚拟十字键** switch: render a 4-button + centre d-pad in place of
///   the round stick. Best for action / platformer titles that don't
///   understand diagonal input.
class _StickSettingsCard extends StatelessWidget {
  const _StickSettingsCard({
    required this.mode,
    required this.deadzone,
    required this.useDpadUi,
    required this.onModeChanged,
    required this.onDeadzoneChanged,
    required this.onUseDpadUiChanged,
  });

  final String mode;
  final double deadzone;
  final bool useDpadUi;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<double> onDeadzoneChanged;
  final ValueChanged<bool> onUseDpadUiChanged;

  String _modeLabel(String m) => switch (m) {
        'STICK' => '全向（适合 ACT / 平台）',
        'DPAD4' => '4 方向（适合平台跳跃）',
        _ => '8 方向（适合格斗）',
      };

  String _modeHint(String m) => switch (m) {
        'STICK' => '保留模拟量，死区最大，斜方向全部输出',
        'DPAD4' => '每个方向按键只出一个方位，斜方向吸附到最近',
        _ => '8 方向精准，斜方向可出（KOF97 推荐）',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gamepad_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('摇杆 / 方向键', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            // Mode picker — three-way segmented button.
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'STICK', label: Text('全向')),
                ButtonSegment(value: 'DPAD8', label: Text('8 向')),
                ButtonSegment(value: 'DPAD4', label: Text('4 向')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (set) => onModeChanged(set.first),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _modeHint(mode),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            const SizedBox(height: 14),
            // Dead-zone slider.
            Row(
              children: [
                const Icon(Icons.adjust, size: 18),
                const SizedBox(width: 8),
                Text('死区', style: theme.textTheme.bodyMedium),
                const Spacer(),
                Text(
                  deadzone.toStringAsFixed(2),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Slider(
              value: deadzone.clamp(0.0, 0.45),
              min: 0.0,
              max: 0.45,
              divisions: 45,
              label: deadzone.toStringAsFixed(2),
              onChanged: onDeadzoneChanged,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '小于此偏移视为回中（格斗建议 0.10–0.15，简单游戏 0.20–0.30）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            const SizedBox(height: 4),
            // D-pad UI toggle.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.control_camera_outlined),
              title: const Text('使用虚拟十字键（替代摇杆）'),
              subtitle: const Text(
                  '隐藏摇杆，显示 4 个方向大按钮，适合 ACT / 平台跳跃'),
              value: useDpadUi,
              onChanged: onUseDpadUiChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// 虚拟手柄整体布局：在默认大小/位置基础上，整体缩放 + 整体平移（左右上下）。
/// 适配不同手机屏幕与握持习惯；支持导入/导出布局配置（JSON）。
class _PadLayoutCard extends StatefulWidget {
  const _PadLayoutCard({
    required this.settings,
    required this.pal,
    required this.patch,
  });

  final AppSettings settings;
  final PlatformPal pal;
  final void Function(void Function(AppSettings)) patch;

  @override
  State<_PadLayoutCard> createState() => _PadLayoutCardState();
}

class _PadLayoutCardState extends State<_PadLayoutCard> {
  bool _busy = false;
  String? _msg;
  bool _msgIsError = false;

  void _setMsg(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _msg = text;
      _msgIsError = error;
    });
  }

  Future<void> _reset() async {
    widget.patch((s) {
      s.padScale = 1.0;
      s.padOffsetX = 0.0;
      s.padOffsetY = 0.0;
    });
    _setMsg('已恢复默认布局');
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final r = await widget.pal.importPadConfigViaSaf();
      if (r == null) {
        _setMsg('已取消');
        return;
      }
      if (!r.ok) {
        _setMsg('文件不是有效的 JSON', error: true);
        return;
      }
      final json = jsonDecode(await File(r.path).readAsString()) as Map<String, dynamic>;
      final scale = (json['scale'] as num?)?.toDouble();
      final ox = (json['offsetX'] as num?)?.toDouble();
      final oy = (json['offsetY'] as num?)?.toDouble();
      if (scale == null && ox == null && oy == null) {
        _setMsg('缺少 scale / offsetX / offsetY 字段', error: true);
        return;
      }
      widget.patch((s) {
        if (scale != null) s.padScale = scale.clamp(0.5, 2.5);
        if (ox != null) s.padOffsetX = ox.clamp(-0.45, 0.45);
        if (oy != null) s.padOffsetY = oy.clamp(-0.45, 0.45);
      });
      _setMsg('已导入布局（缩放 ${scale ?? widget.settings.padScale}，'
          'X ${ox ?? 0} Y ${oy ?? 0}）');
    } catch (e) {
      _setMsg('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final dir = await widget.pal.filesDir();
      final src =
          File('$dir/library/pad_layout_export.json');
      // OHOS/Android both keep `library/` around, but a fresh sandbox may not
      // have it yet — create it so the export never fails with ENOENT.
      await src.parent.create(recursive: true);
      await src.writeAsString(jsonEncode({
        'scale': widget.settings.padScale,
        'offsetX': widget.settings.padOffsetX,
        'offsetY': widget.settings.padOffsetY,
      }));
      final ok = await widget.pal.exportPadConfigViaSaf(
        sourcePath: src.path,
        suggestedName: 'gamepouch_pad_layout.json',
      );
      _setMsg(ok ? '已导出' : '已取消');
    } catch (e) {
      _setMsg('导出失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.settings;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('虚拟手柄布局', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _reset,
                  child: const Text('恢复默认'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('整体缩放', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Slider(
              value: s.padScale.clamp(0.5, 2.5),
              min: 0.5,
              max: 2.5,
              divisions: 40,
              label: s.padScale.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padScale = v),
            ),
            Text('以默认大小为基准，0.5–2.5 倍',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Text('水平平移', style: TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: s.padOffsetX.clamp(-0.45, 0.45),
              min: -0.45,
              max: 0.45,
              divisions: 90,
              label: s.padOffsetX.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padOffsetX = v),
            ),
            Text('负值向左、正值向右（相对屏幕宽度）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Text('垂直平移', style: TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: s.padOffsetY.clamp(-0.45, 0.45),
              min: -0.45,
              max: 0.45,
              divisions: 90,
              label: s.padOffsetY.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padOffsetY = v),
            ),
            Text('负值向上、正值向下（相对屏幕高度）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open),
                    label: const Text('导入配置'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出配置'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_msg != null) ...[
              const SizedBox(height: 10),
              Text(
                _msg!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _msgIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}