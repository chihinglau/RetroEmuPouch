import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eula_page.dart';
import 'privacy_policy_page.dart';

/// First-launch consent gate (R8). Blocks app entry until the user has read
/// and accepted the privacy policy + EULA, persisting the choice in
/// `SharedPreferences` so it is shown only once.
class ConsentGate extends StatelessWidget {
  const ConsentGate({super.key, required this.onAccept});

  final VoidCallback onAccept;

  static const String _kConsent = 'consent_given';

  Future<void> _accept() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kConsent, true);
    onAccept();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4FC3F7),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('欢迎使用 趣玩匣 RetroEmuPouch',
                    style: theme.textTheme.headlineSmall),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      '本应用为复古游戏模拟器，不内置任何游戏、ROM 或 BIOS 文件。'
                      '游戏资源需由您自行导入，且您应确保其来源合法（如自有备份）。\n\n'
                      '使用前请阅读并同意以下文档：\n'
                      '· 隐私政策（我们如何收集、使用与保护您的数据）\n'
                      '· 用户协议（免责与知识产权声明）\n\n'
                      '点击「同意并继续」即表示您已阅读并理解上述文档。',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const PrivacyPolicyPage()),
                      ),
                      child: const Text('查看隐私政策'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const EulaPage()),
                      ),
                      child: const Text('查看用户协议'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => SystemNavigator.pop(),
                        child: const Text('不同意并退出'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _accept,
                        child: const Text('同意并继续'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
