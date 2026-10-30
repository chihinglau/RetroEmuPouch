import 'package:flutter/material.dart';

import '../../data/cloud/cloud_client.dart';
import '../../data/cloud/cloud_config.dart';
import '../../data/cloud/cloud_sync.dart';

/// Full-screen progress dialog while a network sync runs. Returns the report
/// when finished, or null if it failed.
Future<SyncReport?> runCloudSync(
  BuildContext context, {
  required CloudConfig config,
  required String filesDir,
}) async {
  SyncReport? report;
  String? error;
  var started = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      String stage = '准备中…';
      double? progress;
      return StatefulBuilder(
        builder: (ctx, setDlg) {
          void start() {
            if (started) return;
            started = true;
            final client = CloudClient(config);
            final syncer = CloudSyncer(
              client: client,
              config: config,
              filesDir: filesDir,
            );
            syncer.sync(onProgress: (s, p) {
              setDlg(() {
                stage = s;
                progress = p;
              });
            }).then((r) {
              report = r;
              if (ctx.mounted) Navigator.of(ctx).pop();
            }).catchError((Object e) {
              error = '$e';
              setDlg(() {});
            });
          }

          WidgetsBinding.instance.addPostFrameCallback((_) => start());

          return PopScope(
            canPop: error != null,
            child: Dialog(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.cloud_sync, size: 22),
                        const SizedBox(width: 10),
                        Text('网络同步',
                            style: Theme.of(ctx).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(stage),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: progress),
                    if (error != null) ...[
                      const SizedBox(height: 14),
                      Text('同步失败：$error',
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error)),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
  return report;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
}
