import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:retroemupouch/features/legal/legal_constants.dart';

/// 隐私政策（占位模板，正式发布前须经合规审查与 PIPL 个人信息保护影响评估）。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const _text = '''
趣玩匣 RetroEmuPouch 隐私政策（模板）

1. 我们收集的信息
   · 您主动提供的账号信息（邮箱 / 用户名、密码哈希）。
   · 您选择上传的存档、封面与游戏元数据（仅用于跨设备同步）。
   · 设备与网络诊断信息（用于排查问题，不含精确地理位置）。

2. 我们如何使用信息
   · 提供云存档、联机对战、跨设备同步等核心功能。
   · 保障账号安全与防滥用。

3. 信息共享
   · 我们不会向任何第三方出售您的个人信息。
   · 仅在法律法规要求时向有权机关披露。

4. 您的权利
   · 可随时删除账号及全部关联数据。
   · 可撤回授权并导出您的个人数据。

5. 数据存储与安全
   · 凭据以加盐哈希存储；本地登录态存放于应用私有加密存储。
   · 所有传输均采用 TLS。

6. 未成年人保护
   · 本应用不面向未满 14 周岁用户；如识别到，将删除其数据。

（本政策为占位模板，正式发布前须经法务审核。）
''';

  Future<void> _copyWebLink(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: LegalConstants.privacyPolicyUrl),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制网页版隐私政策链接，可在浏览器打开')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('隐私政策')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.language_outlined),
                    title: const Text('网页版隐私政策'),
                    subtitle: const Text(
                      '公网可访问版本（备案 / Google Play Data Safety 使用）',
                    ),
                    trailing: const Icon(Icons.copy_outlined),
                    onTap: () => _copyWebLink(context),
                  ),
                ),
                const SizedBox(height: 12),
                const SelectableText(_text, style: TextStyle(height: 1.5)),
              ],
            ),
          ),
        ),
      );
}
