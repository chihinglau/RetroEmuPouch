import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/play/play_session.dart';

/// Result of the invite dialog.
enum PlayInviteResult { accept, decline, timeout }

/// Guest-side invitation popup. Auto-closes as [PlayInvite.ttl] expires;
/// the host-side TTL timer is authoritative regardless.
class PlayInviteDialog extends StatefulWidget {
  const PlayInviteDialog({super.key, required this.invite});

  final PlayInvite invite;

  static Future<PlayInviteResult?> show(
    BuildContext context, {
    required PlayInvite invite,
  }) {
    return showDialog<PlayInviteResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PlayInviteDialog(invite: invite),
    );
  }

  @override
  State<PlayInviteDialog> createState() => _PlayInviteDialogState();
}

class _PlayInviteDialogState extends State<PlayInviteDialog> {
  Timer? _tick;
  Duration _left = Duration.zero;

  @override
  void initState() {
    super.initState();
    _left = widget.invite.ttl;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = widget.invite.ttl;
      if (!mounted) return;
      if (left.inSeconds <= 0) {
        Navigator.of(context).pop(PlayInviteResult.timeout);
        return;
      }
      setState(() => _left = left);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    return AlertDialog(
      icon: const Icon(Icons.sports_esports, size: 36),
      title: const Text('联机游戏邀请'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(inv.romName,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          Text('来自：${inv.fromName}'),
          const SizedBox(height: 6),
          Text(
            inv.coreId == 'mame' || inv.coreId == 'fbalpha2012'
                ? '街机 · 你将作为 2P 加入'
                : 'NES / FC · 你将作为 2P 加入',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Text('邀请 ${_left.inSeconds} 秒后自动过期',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(PlayInviteResult.decline),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(PlayInviteResult.accept),
          child: const Text('接受'),
        ),
      ],
    );
  }
}
