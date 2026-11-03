import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud_config_service.dart';

/// 用户协议页：启动时从后端拉 Markdown 正文，网络失败 fallback 到
/// 本文件底部的硬编码模板。
///
/// 后端 API：`GET /api/cms/docs/eula?lang=zh`
class EulaPage extends StatefulWidget {
  const EulaPage({super.key});

  @override
  State<EulaPage> createState() => _EulaPageState();
}

class _EulaPageState extends State<EulaPage> {
  String? _remoteContent;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final c = await CloudConfigService.instance.fetchDoc('eula');
    if (mounted) {
      setState(() {
        _remoteContent = c;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('用户协议')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : SelectableText(
                    _remoteContent ?? _fallback,
                    style: const TextStyle(height: 1.5),
                  ),
          ),
        ),
      );

  static const _fallback = '''
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
}
