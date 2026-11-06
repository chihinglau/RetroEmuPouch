import 'package:flutter/material.dart';

import '../../pal/platform_pal.dart' show PlatformPal;
import 'cloud_save_section.dart' show CloudSaveSection;

/// 云存档独立页面：从「网络」页点入口进入，避免云存档较长的内容
/// 挤压同页的「发现伙伴」等入口。与「发现伙伴 → PeersPage」保持一致的
/// "聚合入口 → 独立页" 信息架构。
class CloudSavePage extends StatelessWidget {
  const CloudSavePage({
    super.key,
    required this.userId,
    required this.pal,
  });

  final String userId;
  final PlatformPal pal;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云存档')),
      body: userId.isEmpty
          ? const _LockedHint()
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              child: CloudSaveSection(userId: userId, pal: pal),
            ),
    );
  }
}

/// 未登录态引导（与登录入口分离，移入独立页展示）。
class _LockedHint extends StatelessWidget {
  const _LockedHint();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('登录云端账号后可同步存档与设置，并解锁会员权益。'),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('先登录账号 · 云存档需会员',
                      style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
