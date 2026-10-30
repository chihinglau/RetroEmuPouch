import 'package:flutter/material.dart';

/// 用户协议（占位模板，含免责与知识产权声明；正式发布前须经法务审核）。
class EulaPage extends StatelessWidget {
  const EulaPage({super.key});

  static const _text = '''
趣玩匣 RetroEmuPouch 用户协议（模板）

1. 知识产权
   · 本应用为复古游戏模拟器，本身不内置任何游戏、ROM 或 BIOS 文件。
   · 所有游戏资源须由用户自行导入，且用户应确保其来源合法（如自有备份）。
   · 本应用与任何游戏机厂商、游戏发行商均无关联。

2. 使用许可
   · 授予您非独占、不可转让的个人非商业使用许可。
   · 不得用于任何商业分发或营利性场景。

3. 免责声明
   · 因使用本应用导致的任何数据丢失、设备损坏或法律责任，开发者不承担责任。
   · 用户对其导入的游戏资源之合法性负全部责任。

4. 终止
   · 如您违反本协议，开发者可随时终止您的访问权限。

（本协议为占位模板，正式发布前须经法务审核。）
''';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('用户协议')),
        body: const SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: SelectableText(_text, style: TextStyle(height: 1.5)),
          ),
        ),
      );
}
