import 'package:flutter/material.dart';

import '../../protocol/models.dart';

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.isSubmitting,
    required this.onAction,
  });

  final PendingApproval approval;
  final bool isSubmitting;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    approval.operationKind,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_formatExpiry(approval.expiresAt)),
              ],
            ),
            const SizedBox(height: 8),
            Text(approval.description),
            if (approval.paths.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final path in approval.paths)
                    Chip(
                      avatar: const Icon(Icons.insert_drive_file, size: 16),
                      label: Text(path),
                    ),
                ],
              ),
            ],
            if (approval.diffSummary != null &&
                approval.diffSummary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                approval.diffSummary!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in approval.actions)
                  FilledButton.icon(
                    icon: isSubmitting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(_actionIcon(action)),
                    label: Text(action),
                    onPressed:
                        isSubmitting ? null : () => onAction(action),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _actionIcon(String action) {
    switch (action) {
      case 'approve':
      case 'yes':
      case 'accept':
        return Icons.check;
      case 'reject':
      case 'no':
      case 'deny':
        return Icons.close;
      case 'always':
        return Icons.done_all;
      default:
        return Icons.touch_app;
    }
  }

  String _formatExpiry(DateTime expiresAt) {
    final local = expiresAt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return 'expires $hour:$minute';
  }
}
