import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../protocol/models.dart';

class ApprovalCard extends StatefulWidget {
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
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  Timer? _expiryTimer;
  String? _pendingAction;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _restartExpiryTimer();
    _triggerAppearanceHaptic();
  }

  @override
  void didUpdateWidget(ApprovalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final approvalChanged =
        oldWidget.approval.approvalId != widget.approval.approvalId ||
        oldWidget.approval.contentHash != widget.approval.contentHash;
    if (approvalChanged) {
      _pendingAction = null;
      _triggerAppearanceHaptic();
    }
    if (approvalChanged ||
        oldWidget.approval.expiresAt != widget.approval.expiresAt ||
        oldWidget.approval.status != widget.approval.status) {
      _restartExpiryTimer();
    }
    if (oldWidget.isSubmitting && !widget.isSubmitting) {
      setState(() => _pendingAction = null);
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  bool _isActive(String action) =>
      widget.isSubmitting && _pendingAction == action;

  Duration get _remaining => widget.approval.expiresAt.difference(_now);

  bool get _isExpired =>
      widget.approval.status == 'expired' ||
      widget.approval.expiresAt.difference(_now).inMilliseconds <= 0;

  bool _isExpiredAt(DateTime now) =>
      widget.approval.status == 'expired' ||
      widget.approval.expiresAt.difference(now).inMilliseconds <= 0;

  Future<void> _submitAction(BuildContext context, String action) async {
    if (_refreshExpiredNow()) return;
    if (action == 'always') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Always approve?'),
          content: const Text(
            'This applies only to matching low-risk actions in this session.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.done_all),
              label: const Text('Always'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    if (_refreshExpiredNow()) return;
    setState(() => _pendingAction = action);
    widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final approval = widget.approval;
    final remaining = _remaining;
    final isExpired = _isExpired;
    final commandContent = _commandContent(approval);
    final description = commandContent?.description ?? approval.description;
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
                    _operationLabel(approval.operationKind),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  _formatExpiry(remaining, isExpired: isExpired),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: _expiryColor(
                          colorScheme,
                          remaining,
                          isExpired: isExpired,
                        ),
                        fontWeight: isExpired || remaining.inSeconds < 60
                            ? FontWeight.w600
                            : null,
                      ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(description),
            ],
            if (commandContent != null) ...[
              const SizedBox(height: 8),
              _CommandBlock(command: commandContent.command),
            ],
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
              _DiffSummary(diffSummary: approval.diffSummary!),
            ],
            const SizedBox(height: 12),
            approval.operationKind == 'choice' && approval.choices.isNotEmpty
                ? _ChoiceButtons(
                    choices: approval.choices,
                    isSubmitting: widget.isSubmitting,
                    isExpired: isExpired,
                    pendingAction: _pendingAction,
                    onAction: (action) => _submitAction(context, action),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action in approval.actions)
                        _isRejectAction(action)
                            ? OutlinedButton.icon(
                                icon: _isActive(action)
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(_actionIcon(action)),
                                label: Text(_actionLabel(action)),
                                onPressed: widget.isSubmitting || isExpired
                                    ? null
                                    : () => _submitAction(context, action),
                              )
                            : FilledButton.icon(
                                icon: _isActive(action)
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(_actionIcon(action)),
                                label: Text(_actionLabel(action)),
                                onPressed: widget.isSubmitting || isExpired
                                    ? null
                                    : () => _submitAction(context, action),
                              ),
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  String _operationLabel(String operationKind) {
    switch (operationKind) {
      case 'file_edit':
        return 'File change approval';
      case 'command':
        return 'Command approval';
      case 'choice':
        return 'Choice required';
      default:
        return 'Approval required';
    }
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'approve':
      case 'yes':
      case 'accept':
        return 'Accept';
      case 'reject':
      case 'no':
      case 'deny':
        return 'Reject';
      case 'always':
        return 'Always for this session';
      case 'choice':
        return 'Choose';
      default:
        return action;
    }
  }

  bool _isRejectAction(String action) {
    return action == 'reject' || action == 'no' || action == 'deny';
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

  void _restartExpiryTimer() {
    _expiryTimer?.cancel();
    _now = DateTime.now();
    if (_isExpired) {
      _expiryTimer = null;
      return;
    }
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      setState(() => _now = now);
      if (_isExpiredAt(now)) {
        timer.cancel();
        _expiryTimer = null;
      }
    });
  }

  bool _refreshExpiredNow() {
    final now = DateTime.now();
    if (!_isExpiredAt(now)) return false;
    setState(() => _now = now);
    _expiryTimer?.cancel();
    _expiryTimer = null;
    return true;
  }

  void _triggerAppearanceHaptic() {
    unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
  }

  Color? _expiryColor(
    ColorScheme colorScheme,
    Duration remaining, {
    required bool isExpired,
  }) {
    if (isExpired || remaining.inSeconds < 60) {
      return colorScheme.error;
    }
    return null;
  }

  String _formatExpiry(Duration remaining, {required bool isExpired}) {
    if (isExpired) return 'expired';
    final totalSeconds = (remaining.inMilliseconds / 1000).ceil();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final secondsText = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final minutesText = minutes.toString().padLeft(2, '0');
      return 'expires in $hours:$minutesText:$secondsText';
    }
    return 'expires in $minutes:$secondsText';
  }

  _CommandContent? _commandContent(PendingApproval approval) {
    if (approval.operationKind != 'command') return null;
    final description = approval.description.trim();
    if (description.isEmpty) return null;
    return _splitCommandDescription(description);
  }
}

class _CommandContent {
  const _CommandContent({
    required this.description,
    required this.command,
  });

  final String description;
  final String command;
}

_CommandContent _splitCommandDescription(String description) {
  final fencedMatch =
      RegExp(r'```[^\n]*\n([\s\S]*?)```').firstMatch(description);
  if (fencedMatch != null) {
    return _CommandContent(
      description: _cleanCommandDescription(
        description.replaceRange(
          fencedMatch.start,
          fencedMatch.end,
          '',
        ),
      ),
      command: fencedMatch.group(1)!.trim(),
    );
  }

  final inlineMatches =
      RegExp(r'`([^`\n]+)`').allMatches(description).toList();
  if (inlineMatches.length == 1) {
    final match = inlineMatches.single;
    return _CommandContent(
      description: _cleanCommandDescription(
        '${description.substring(0, match.start)} '
        '${description.substring(match.end)}',
      ),
      command: match.group(1)!.trim(),
    );
  }

  final paragraphBreak = RegExp(r'\n\s*\n').firstMatch(description);
  if (paragraphBreak != null) {
    return _CommandContent(
      description: _cleanCommandDescription(
        description.substring(0, paragraphBreak.start),
      ),
      command: description.substring(paragraphBreak.end).trim(),
    );
  }

  final lines = description
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length > 1) {
    return _CommandContent(
      description: _cleanCommandDescription(lines.first),
      command: lines.skip(1).join('\n').trim(),
    );
  }

  final colonMatch =
      RegExp(r'^(.*(?:command|run|execute|运行|执行).*?):\s*(.+)$',
              caseSensitive: false)
          .firstMatch(description);
  if (colonMatch != null) {
    return _CommandContent(
      description: _cleanCommandDescription(colonMatch.group(1)!),
      command: colonMatch.group(2)!.trim(),
    );
  }

  return _CommandContent(description: '', command: description);
}

String _cleanCommandDescription(String description) {
  return description
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s+([?.!,;:])'), (match) => match.group(1)!)
      .trim();
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final background = isDark ? colorScheme.surface : const Color(0xFF1F2937);
    final foreground =
        isDark ? colorScheme.onSurface : colorScheme.onInverseSurface;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: isDark ? Border.all(color: colorScheme.outlineVariant) : null,
      ),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          command,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: foreground,
                fontFamily: 'monospace',
              ),
        ),
      ),
    );
  }
}

class _DiffSummary extends StatelessWidget {
  const _DiffSummary({required this.diffSummary});

  final String diffSummary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
        );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText.rich(
          TextSpan(
            style: baseStyle,
            children: _diffLineSpans(diffSummary, colorScheme, baseStyle),
          ),
        ),
      ),
    );
  }

  List<TextSpan> _diffLineSpans(
    String diffSummary,
    ColorScheme colorScheme,
    TextStyle? baseStyle,
  ) {
    final lines = diffSummary.split('\n');
    return [
      for (var index = 0; index < lines.length; index++)
        TextSpan(
          text: index == lines.length - 1 ? lines[index] : '${lines[index]}\n',
          style: baseStyle?.copyWith(
            color: _diffLineColor(lines[index], colorScheme),
          ),
        ),
    ];
  }

  Color? _diffLineColor(String line, ColorScheme colorScheme) {
    if (line.startsWith('@@')) return colorScheme.onSurfaceVariant;
    if (line.startsWith('+')) {
      return colorScheme.brightness == Brightness.dark
          ? Colors.greenAccent.shade400
          : Colors.green.shade700;
    }
    if (line.startsWith('-')) return colorScheme.error;
    return null;
  }
}

class _ChoiceButtons extends StatelessWidget {
  const _ChoiceButtons({
    required this.choices,
    required this.isSubmitting,
    required this.isExpired,
    required this.pendingAction,
    required this.onAction,
  });

  final List<ApprovalChoice> choices;
  final bool isSubmitting;
  final bool isExpired;
  final String? pendingAction;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final choice in choices) ...[
          FilledButton.tonalIcon(
            icon: (isSubmitting && pendingAction == choice.value)
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.touch_app),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text('${choice.value}. ${choice.label}'),
            ),
            onPressed:
                isSubmitting || isExpired ? null : () => onAction(choice.value),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
