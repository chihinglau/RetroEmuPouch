import 'package:flutter/material.dart';

/// 云文件库浏览页（**暂不可用**）。
///
/// 原实现对接 PC 管理台 `/api/cloud/catalog` + subscriptions，
/// RetroEmuPouch 账号后端没有这些路由；独立服务尚未接入。
/// 显示"即将上线"占位，保留 [config] / [filesDir] 参数签名兼容未来恢复。
class CloudLibraryPage extends StatelessWidget {
  const CloudLibraryPage({super.key, required this.config, required this.filesDir});
  final dynamic config;
  final String filesDir;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云文件库')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48),
              SizedBox(height: 16),
              Text('云文件库功能即将上线',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16)),
              SizedBox(height: 8),
              Text('当前版本支持账号登录与云存档，'
                  'PC 管理台 catalog 同步待接入。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
