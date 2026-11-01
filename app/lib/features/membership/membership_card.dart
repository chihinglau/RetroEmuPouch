import 'package:flutter/material.dart';

import 'entitlement_service.dart';
import 'membership.dart';

/// AccountPage section: membership status, 7-day trial, and upgrade actions.
/// Uses a [FutureBuilder] over [Membership.instance] so it needs no async state
/// in the host page.
class MembershipSection extends StatelessWidget {
  const MembershipSection({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Membership>(
      future: Membership.instance,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          );
        }
        return _MembershipCard(membership: snap.data!);
      },
    );
  }
}

class _MembershipCard extends StatefulWidget {
  const _MembershipCard({required this.membership});
  final Membership membership;

  @override
  State<_MembershipCard> createState() => _MembershipCardState();
}

class _MembershipCardState extends State<_MembershipCard> {
  @override
  void initState() {
    super.initState();
    widget.membership.entitlement.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.membership.entitlement;
    final tier = e.current.effectiveTier;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.workspace_premium, size: 20),
                SizedBox(width: 8),
                Text('会员 / 去广告',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '当前状态：${tier.label}${e.isAdFree ? '（已去广告）' : '（含广告）'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              e.current.cloudSaveEnabled
                  ? '已开通云存档（更多备份位 / 更大存档）'
                  : '升级会员解锁云存档权益',
              style: theme.textTheme.bodySmall?.copyWith(
                color: e.current.cloudSaveEnabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            if (tier == MembershipTier.free && e.current.trialStart == null)
              FilledButton(
                onPressed: () async => e.ensureTrialStarted(),
                child: const Text('开始 7 天免费试用'),
              )
            else if (tier == MembershipTier.trial)
              Text('试用剩余 ${e.trialRemainingDays} 天',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      widget.membership.billing.buy(MembershipTier.monthly),
                  child: const Text('月会员'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      widget.membership.billing.buy(MembershipTier.yearly),
                  child: const Text('年会员'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      widget.membership.billing.buy(MembershipTier.lifetime),
                  child: const Text('终身会员'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
