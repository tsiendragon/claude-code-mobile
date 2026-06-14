import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../../core/theme/ccm_motion.dart';
import '../../core/theme/ccm_tokens.dart';
import '../../core/utils/format_utils.dart';
import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../approvals/approval_card.dart';

part 'chat_files.dart';

const _linkChannel = MethodChannel('ccm_mobile/links');
const _mediaChannel = MethodChannel('ccm_mobile/media');
const _assistantStreamFrameDelay = Duration(milliseconds: 40);

/// Index of the existing assistant bubble that [incoming] continues, or -1 to
/// append a new one.
///
/// Beyond an exact id match, the bridge can re-id the SAME growing assistant
/// turn across polls (e.g. "A+B" then "A+B+C" with different message ids). To
/// avoid rendering that as two bubbles, we treat [incoming] as the same message
/// when it equals — or grows from — the last assistant bubble's shown or full
/// text, so the caller applies only the increment. A new turn is always
/// separated by a user message, so this never merges distinct turns.
int assistantMergeIndex(
  List<ChatItem> items,
  ChatItem incoming,
  String Function(ChatItem) shownTextOf,
) {
  final byId = items.indexWhere((existing) => existing.id == incoming.id);
  if (byId >= 0) return byId;
  if (items.isEmpty) return -1;
  final lastIndex = items.length - 1;
  final last = items[lastIndex];
  if (last.role != ChatItemRole.assistant) return -1;
  final shown = shownTextOf(last);
  if (incoming.text == shown ||
      incoming.text == last.text ||
      incoming.text.startsWith(shown) ||
      incoming.text.startsWith(last.text)) {
    return lastIndex;
  }
  return -1;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.session});

  final SessionSummary session;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<BridgeEventEnvelope>? _eventSubscription;

  SessionSummary? _session;
  List<ChatItem> _items = const [];
  List<_PendingImageAttachment> _pendingImages = const [];
  final Set<String> _expandedMessageIds = <String>{};
  // Ids whose one-shot entrance has played, so it never re-fires on scroll
  // recycling or stream-frame rebuilds.
  final Set<String> _animatedInIds = <String>{};
  final Map<String, _AssistantMessageAnimation> _assistantAnimations =
      <String, _AssistantMessageAnimation>{};
  PendingApproval? _pendingApproval;
  bool _isLoading = true;
  bool _isLoadingHistory = false;
  bool _hasMoreHistory = false;
  bool _isSending = false;
  bool _isApproving = false;
  bool _isRecoveringEventGap = false;
  bool _hasEventGap = false;
  bool _showJumpToBottom = false;
  int? _historyBefore;
  String? _error;
  String? _eventGapError;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attach();
      final client = context.read<BridgeClient>();
      _eventSubscription = client.events.listen(_handleEvent);
    });
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.sessionId == widget.session.sessionId) return;
    _clearAssistantAnimations();
    _session = widget.session;
    _items = const [];
    _pendingApproval = null;
    _expandedMessageIds.clear();
    _animatedInIds.clear();
    _hasEventGap = false;
    _showJumpToBottom = false;
    _historyBefore = null;
    _hasMoreHistory = false;
    _isLoading = true;
    unawaited(_attach());
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _clearAssistantAnimations(deferDispose: false);
    _scrollController.removeListener(_handleScroll);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final canSend = (_canSendText(session.state) || _pendingApproval != null) &&
        !_isSending;
    final canAttachImages = session.state == SessionState.ready &&
        _pendingApproval == null &&
        !_isSending &&
        _pendingImages.length < 4;
    final canInterrupt = session.state == SessionState.thinking ||
        session.state == SessionState.approval ||
        session.state == SessionState.choosing;
    final inputHint = _inputHint(session.state);
    final textFieldHint = _textFieldHint(session.state);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.name),
            Text(
              '${sessionBackendLabel(session.backend)} · ${sessionStateLabel(session.state)}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Files',
            icon: const Icon(Icons.folder_open),
            onPressed: _openFileList,
          ),
          IconButton(
            tooltip: 'Interrupt',
            icon: const Icon(Icons.stop),
            onPressed: canInterrupt ? _interrupt : null,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _attach,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_hasEventGap)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _eventGapError == null
                            ? 'Could not refresh the latest messages.'
                            : 'Could not refresh the latest messages: $_eventGapError',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      icon: _isRecoveringEventGap
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed:
                          _isRecoveringEventGap ? null : _recoverEventGap,
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(_error!)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _error = null),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Stack(
                      children: [
                        ListView.builder(
                          controller: _scrollController,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 72),
                          itemCount: _items.length +
                              (_showHistoryHeader ? 1 : 0) +
                              (_hasTrailingItem ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (_showHistoryHeader && index == 0) {
                              return _HistoryLoader(
                                isLoading: _isLoadingHistory,
                                onPressed: _loadEarlierMessages,
                              );
                            }

                            final itemIndex =
                                index - (_showHistoryHeader ? 1 : 0);
                            if (itemIndex < _items.length) {
                              final item = _items[itemIndex];
                              // Animate only a freshly-appended last item, once;
                              // history prepends and scroll recycling never
                              // re-fire it (gated by _animatedInIds).
                              final isNewLast =
                                  itemIndex == _items.length - 1 &&
                                      !_animatedInIds.contains(item.id);
                              if (isNewLast) _animatedInIds.add(item.id);
                              // RepaintBoundary so a streaming bubble's frequent
                              // repaints don't dirty the rest of the list.
                              return RepaintBoundary(
                                key: ValueKey(item.id),
                                child: _EntranceFade(
                                  animate: isNewLast &&
                                      !CcmMotion.reduceMotionOf(context),
                                  child: _ChatBubble(
                                    sessionId: widget.session.sessionId,
                                    item: item,
                                    animation: _assistantAnimations[item.id],
                                    expanded:
                                        _expandedMessageIds.contains(item.id),
                                    onToggleExpanded: () =>
                                        _toggleExpanded(item.id),
                                    onOpenFile: _openFilePreview,
                                    onRetry: item.failed && !_isSending
                                        ? () => _retryFailedMessage(item)
                                        : null,
                                    onFeedback:
                                        item.role == ChatItemRole.assistant &&
                                                item.seq != null &&
                                                !item.pending
                                            ? () => _showFeedbackSheet(item)
                                            : null,
                                  ),
                                ),
                              );
                            }

                            if (_pendingApproval != null) {
                              final approvalId = _pendingApproval!.approvalId;
                              final animateApproval =
                                  !_animatedInIds.contains(approvalId) &&
                                      !CcmMotion.reduceMotionOf(context);
                              _animatedInIds.add(approvalId);
                              return _EntranceFade(
                                animate: animateApproval,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: ApprovalCard(
                                    approval: _pendingApproval!,
                                    isSubmitting: _isApproving,
                                    onAction: _approve,
                                  ),
                                ),
                              );
                            }
                            return const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: _ThinkingBubble(),
                            );
                          },
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: Center(
                            child: AnimatedScale(
                              scale: _showJumpToBottom ? 1 : 0.85,
                              duration: CcmMotion.reduceMotionOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              child: AnimatedOpacity(
                                opacity: _showJumpToBottom ? 1 : 0,
                                duration: CcmMotion.reduceMotionOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 160),
                                child: IgnorePointer(
                                  ignoring: !_showJumpToBottom,
                                  child: FilledButton.tonalIcon(
                                    icon: const Icon(Icons.keyboard_arrow_down),
                                    label: const Text('New messages'),
                                    onPressed: _scrollToBottom,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (inputHint != null) ...[
                    Text(
                      inputHint,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (_pendingImages.isNotEmpty) ...[
                    _PendingImageStrip(
                      images: _pendingImages,
                      onRemove: _removePendingImage,
                    ),
                    const SizedBox(height: 8),
                  ],
                  // One tactile pill: attach + field + send read as a single
                  // tool, the field borderless so the pill is the container.
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Attach image',
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          onPressed: canAttachImages ? _pickImage : null,
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            enabled: canSend,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: textFieldHint,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onSubmitted: (_) => canSend ? _send() : null,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton.filled(
                          tooltip: 'Send',
                          icon: _isSending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send),
                          onPressed: canSend ? _send : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _attach() async {
    _clearAssistantAnimations();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final snapshot = await context
          .read<BridgeClient>()
          .attachSession(widget.session.sessionId);
      setState(() {
        _applySnapshot(snapshot);
      });
      _scrollToBottom();
    } on BridgeException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applySnapshot(ChatStateSnapshot snapshot) {
    _session = snapshot.session;
    _items = snapshot.items;
    _hasMoreHistory = snapshot.hasMoreHistory;
    _historyBefore = snapshot.nextHistoryBefore;
    _expandedMessageIds
        .removeWhere((id) => !_items.any((item) => item.id == id));
    _pendingApproval = snapshot.pendingApproval;
    _hasEventGap = false;
    _eventGapError = null;
    _showJumpToBottom = false;
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    final attachments = List<_PendingImageAttachment>.from(_pendingImages);
    if (text.isEmpty && attachments.isEmpty) return;
    // Confirm the user's input with a light tap — fire-and-forget so the RPC
    // dispatches on the same frame.
    unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    final currentState = (_session ?? widget.session).state;
    final useCommand = _pendingApproval != null ||
        currentState == SessionState.approval ||
        currentState == SessionState.choosing;
    if (useCommand && attachments.isNotEmpty) {
      setState(() => _error = 'Images can only be attached to normal prompts.');
      return;
    }
    _finishAssistantAnimations();

    final clientMessageId =
        'cmsg_${DateTime.now().microsecondsSinceEpoch.toString()}';
    final optimistic = ChatItem(
      id: clientMessageId,
      role: ChatItemRole.user,
      text: _localPromptText(text, attachments),
      pending: true,
    );

    setState(() {
      _isSending = true;
      _items = [..._items, optimistic];
      _pendingImages = const [];
      _messageController.clear();
    });
    _scrollToBottom();

    try {
      final client = context.read<BridgeClient>();
      final prompt = attachments.isEmpty
          ? text
          : await _uploadImagesAndBuildPrompt(text, attachments);
      if (useCommand) {
        await client.sendCommand(
          sessionId: widget.session.sessionId,
          clientMessageId: clientMessageId,
          command: prompt,
        );
      } else {
        await client.sendMessage(
          sessionId: widget.session.sessionId,
          clientMessageId: clientMessageId,
          text: prompt,
        );
      }
      _replaceItem(
        clientMessageId,
        ChatItem(
          id: clientMessageId,
          role: ChatItemRole.user,
          text: prompt,
          pending: false,
        ),
      );
    } on BridgeException catch (error) {
      _replaceItem(
        clientMessageId,
        optimistic.copyWith(
          pending: false,
          failed: true,
        ),
      );
      setState(() {
        _error = error.message;
        _pendingImages = attachments;
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _retryFailedMessage(ChatItem failedItem) async {
    if (_isSending || !failedItem.failed) return;

    final clientMessageId =
        'cmsg_${DateTime.now().microsecondsSinceEpoch.toString()}';
    final retryItem = ChatItem(
      id: clientMessageId,
      role: ChatItemRole.user,
      text: failedItem.text,
      pending: true,
    );
    final failedIndex = _items.indexWhere((item) => item.id == failedItem.id);

    setState(() {
      _isSending = true;
      _error = null;
      if (failedIndex >= 0) {
        _items = [
          ..._items.take(failedIndex + 1),
          retryItem,
          ..._items.skip(failedIndex + 1),
        ];
      } else {
        _items = [..._items, retryItem];
      }
    });
    _scrollToBottom();

    try {
      await context.read<BridgeClient>().sendMessage(
            sessionId: widget.session.sessionId,
            clientMessageId: clientMessageId,
            text: failedItem.text,
          );
      if (!mounted) return;
      setState(() {
        _items = _items
            .where((item) => item.id != failedItem.id)
            .map((item) => item.id == clientMessageId
                ? item.copyWith(pending: false, failed: false)
                : item)
            .toList();
      });
    } on BridgeException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        // Replace the original failed item with the retry item (also failed),
        // keeping exactly one bubble in the list rather than leaving two.
        _items = _items
            .where((item) => item.id != failedItem.id)
            .map((item) => item.id == clientMessageId
                ? item.copyWith(pending: false, failed: true)
                : item)
            .toList();
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _approve(String action) async {
    final approval = _pendingApproval;
    if (approval == null) return;

    setState(() => _isApproving = true);
    try {
      if (approval.operationKind == 'choice') {
        await context.read<BridgeClient>().sendCommand(
              sessionId: approval.sessionId,
              clientMessageId:
                  'cmsg_${DateTime.now().microsecondsSinceEpoch.toString()}',
              command: action,
            );
      } else {
        await context.read<BridgeClient>().approve(
              sessionId: approval.sessionId,
              approvalId: approval.approvalId,
              action: action,
              idempotencyKey:
                  'idem_${approval.approvalId}_${DateTime.now().microsecondsSinceEpoch}',
            );
      }
      setState(() => _pendingApproval = null);
    } on BridgeException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _isApproving = false);
      }
    }
  }

  Future<void> _interrupt() async {
    _finishAssistantAnimations();
    try {
      await context.read<BridgeClient>().interrupt(widget.session.sessionId);
      setState(() => _pendingApproval = null);
    } on BridgeException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _showFeedbackSheet(ChatItem item) async {
    final seq = item.seq;
    if (seq == null) return;
    final result = await showModalBottomSheet<_FeedbackResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FeedbackSheet(),
    );
    if (result == null || !mounted) return;
    try {
      final artifactsMissing =
          await context.read<BridgeClient>().submitFeedback(
                sessionId: widget.session.sessionId,
                messageSeq: seq,
                messageId: item.id,
                verdict: result.verdict,
                note: result.note,
              );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            artifactsMissing
                ? 'Thanks — feedback saved (original output no longer cached).'
                : 'Thanks — feedback saved.',
          ),
        ),
      );
    } on BridgeException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Feedback failed: ${error.message}')),
      );
    }
  }

  Future<void> _pickImage() async {
    try {
      final raw = await _mediaChannel.invokeMethod<Object?>('pickImage');
      if (!mounted || raw == null) return;
      if (raw is! Map) {
        setState(() => _error = 'Image picker returned an invalid result.');
        return;
      }
      final result = Map<Object?, Object?>.from(raw);
      final bytes = result['bytes'];
      final name = result['name'] as String? ?? 'image';
      final mime = result['mime'] as String? ?? 'image/jpeg';
      if (bytes is! Uint8List || bytes.isEmpty) {
        setState(() => _error = 'Selected image is empty.');
        return;
      }
      if (bytes.length > 10 * 1024 * 1024) {
        setState(() => _error = 'Images must be 10 MB or smaller.');
        return;
      }
      setState(() {
        _pendingImages = [
          ..._pendingImages,
          _PendingImageAttachment(name: name, mime: mime, bytes: bytes),
        ];
        _error = null;
      });
    } on PlatformException catch (error) {
      setState(() => _error = error.message ?? 'Could not pick image.');
    }
  }

  void _removePendingImage(_PendingImageAttachment image) {
    setState(() {
      _pendingImages = _pendingImages.where((item) => item != image).toList();
    });
  }

  Future<String> _uploadImagesAndBuildPrompt(
    String text,
    List<_PendingImageAttachment> attachments,
  ) async {
    final client = context.read<BridgeClient>();
    final uploaded = <FileReference>[];
    for (final image in attachments) {
      uploaded.add(await client.uploadImage(
        sessionId: widget.session.sessionId,
        name: image.name,
        mime: image.mime,
        bytes: image.bytes,
      ));
    }
    final buffer = StringBuffer();
    if (text.isNotEmpty) {
      buffer.writeln(text);
      buffer.writeln();
    }
    buffer.writeln('Attached image file${uploaded.length == 1 ? '' : 's'}:');
    for (final image in uploaded) {
      final displayPath = image.relativePath?.isNotEmpty == true
          ? image.relativePath!
          : image.path;
      buffer.writeln('- ${image.name}: ${image.path} ($displayPath)');
    }
    buffer.writeln();
    buffer.write(
        'Please inspect the attached image file path(s) as part of this request.');
    return buffer.toString();
  }

  String _localPromptText(
    String text,
    List<_PendingImageAttachment> attachments,
  ) {
    if (attachments.isEmpty) return text;
    final buffer = StringBuffer();
    if (text.isNotEmpty) {
      buffer.writeln(text);
      buffer.writeln();
    }
    buffer.writeln('Attached image${attachments.length == 1 ? '' : 's'}:');
    for (final image in attachments) {
      buffer.writeln('- ${image.name} (${formatBytes(image.bytes.length)})');
    }
    return buffer.toString().trimRight();
  }

  void _handleEvent(BridgeEventEnvelope envelope) {
    if (envelope.sessionId != widget.session.sessionId || !mounted) return;

    final event = envelope.event;
    if (event.kind == 'event_gap') {
      unawaited(_recoverEventGap());
      return;
    }

    final shouldAutoScroll = _isNearBottom();
    setState(() {
      switch (event.kind) {
        case 'state_changed':
          _session = SessionSummary(
            sessionId: widget.session.sessionId,
            name: _session?.name ?? widget.session.name,
            backend: _session?.backend ?? widget.session.backend,
            state: sessionStateFromWire(event.payload['state'] as String?),
            lastSeq: envelope.seq,
            cwd: _session?.cwd,
            lastMessage: _session?.lastMessage,
            needsAttention: _session?.needsAttention ?? false,
            lastActiveAt: DateTime.now(),
          );
          break;
        case 'assistant_message':
          final item = ChatItem.fromAssistantEvent(envelope, event.payload);
          if (item.text.isNotEmpty) {
            _handleAssistantMessage(item, shouldAutoScroll);
          }
          break;
        case 'user_message':
          final item = ChatItem.fromUserEvent(envelope, event.payload);
          if (item.text.isNotEmpty) {
            final existingIndex =
                _items.indexWhere((existing) => existing.id == item.id);
            if (existingIndex >= 0) {
              _items = _items
                  .map((existing) => existing.id == item.id ? item : existing)
                  .toList();
            } else {
              _items = [..._items, item];
            }
          }
          break;
        case 'message_delivered':
          final clientId = event.payload['client_msg_id'] as String? ??
              event.payload['clientMsgId'] as String?;
          if (clientId != null) {
            _items = _items
                .map((item) => item.id == clientId
                    ? item.copyWith(pending: false, seq: envelope.seq)
                    : item)
                .toList();
          }
          break;
        case 'message_failed':
          final clientId = event.payload['client_msg_id'] as String? ??
              event.payload['clientMsgId'] as String?;
          if (clientId != null) {
            _items = _items
                .map((item) => item.id == clientId
                    ? item.copyWith(pending: false, failed: true)
                    : item)
                .toList();
          }
          break;
        case 'approval_requested':
          final rawApproval = event.payload['approval'];
          _pendingApproval = PendingApproval.fromJson(
            rawApproval is Map
                ? Map<String, Object?>.from(rawApproval)
                : event.payload,
          );
          break;
        case 'approval_resolved':
          _pendingApproval = null;
          break;
        default:
          break;
      }
    });
    if (shouldAutoScroll) {
      _scrollToBottom();
    } else if (_isMessageEvent(event.kind)) {
      setState(() => _showJumpToBottom = true);
    }
  }

  void _replaceItem(String id, ChatItem replacement) {
    if (!mounted) return;
    setState(() {
      _items =
          _items.map((item) => item.id == id ? replacement : item).toList();
    });
  }

  Future<void> _recoverEventGap() async {
    if (_isRecoveringEventGap) return;

    final shouldAutoScroll = _isNearBottom();
    setState(() {
      _isRecoveringEventGap = true;
      _hasEventGap = false;
      _eventGapError = null;
    });

    try {
      final snapshot = await context
          .read<BridgeClient>()
          .attachSession(widget.session.sessionId);
      if (!mounted) return;
      setState(() => _applySnapshot(snapshot));
      if (shouldAutoScroll) {
        _scrollToBottom();
      }
    } on BridgeException catch (error) {
      if (!mounted) return;
      setState(() {
        _hasEventGap = true;
        _eventGapError = error.message;
      });
    } finally {
      if (mounted) {
        setState(() => _isRecoveringEventGap = false);
      }
    }
  }

  void _handleAssistantMessage(ChatItem item, bool shouldAutoScroll) {
    if (!item.snapshot) {
      _removeAssistantAnimation(item.id);
      _upsertItem(item);
      return;
    }

    final existingIndex = _assistantSnapshotIndex(item);
    if (existingIndex < 0) {
      _items = [..._items, item];
      _startOrUpdateAssistantAnimation(
        itemId: item.id,
        displayedText: '',
        targetText: item.text,
        shouldAutoScroll: shouldAutoScroll,
      );
      return;
    }

    final existing = _items[existingIndex];
    final displayId = existing.id;
    final displayedText = _displayedAssistantText(existing);
    final replacement = displayId == item.id
        ? item
        : existing.copyWith(
            text: item.text,
            seq: item.seq,
            snapshot: item.snapshot,
            pending: item.pending,
            failed: item.failed,
          );

    if (item.text == displayedText) {
      _items = _replaceItemAt(existingIndex, replacement);
      _removeAssistantAnimation(displayId);
      return;
    }

    if (item.text.startsWith(displayedText)) {
      _items = _replaceItemAt(existingIndex, replacement);
      _startOrUpdateAssistantAnimation(
        itemId: displayId,
        displayedText: displayedText,
        targetText: item.text,
        shouldAutoScroll: shouldAutoScroll,
      );
      return;
    }

    _removeAssistantAnimation(displayId);
    if (displayId != item.id) {
      _expandedMessageIds.remove(displayId);
    }
    _items = _replaceItemAt(existingIndex, item);
  }

  int _assistantSnapshotIndex(ChatItem item) =>
      assistantMergeIndex(_items, item, _displayedAssistantText);

  String _displayedAssistantText(ChatItem item) {
    return _assistantAnimations[item.id]?.displayedText ?? item.text;
  }

  List<ChatItem> _replaceItemAt(int index, ChatItem replacement) {
    final updated = List<ChatItem>.from(_items);
    updated[index] = replacement;
    return updated;
  }

  void _startOrUpdateAssistantAnimation({
    required String itemId,
    required String displayedText,
    required String targetText,
    required bool shouldAutoScroll,
  }) {
    if (displayedText == targetText) {
      _removeAssistantAnimation(itemId);
      return;
    }

    final animation = _assistantAnimations[itemId] ??
        _AssistantMessageAnimation(
          displayedText: displayedText,
          targetText: targetText,
        );
    animation.targetText = targetText;
    _assistantAnimations[itemId] = animation;
    _expandedMessageIds.add(itemId);
    _ensureAssistantAnimationTimer(itemId);
    if (shouldAutoScroll) {
      _jumpToBottom();
    }
  }

  void _ensureAssistantAnimationTimer(String itemId) {
    final animation = _assistantAnimations[itemId];
    if (animation == null || animation.timer?.isActive == true) return;
    animation.timer = Timer.periodic(
      _assistantStreamFrameDelay,
      (_) => _tickAssistantAnimation(itemId),
    );
  }

  void _tickAssistantAnimation(String itemId) {
    if (!mounted) return;
    final animation = _assistantAnimations[itemId];
    if (animation == null) return;

    final displayedText = animation.displayedText;
    final targetText = animation.targetText;
    if (displayedText == targetText) {
      _completeAssistantAnimation(itemId);
      return;
    }

    if (!targetText.startsWith(displayedText)) {
      animation.showFinal();
      _completeAssistantAnimation(itemId);
      return;
    }

    final shouldAutoScroll = _isNearBottom();
    final nextEnd = _nextAssistantChunkEnd(targetText, displayedText.length);
    animation.frame.value = _AssistantMessageFrame(
      text: targetText.substring(0, nextEnd),
      isAnimating: true,
    );
    if (shouldAutoScroll) {
      _jumpToBottom();
    }
    if (nextEnd >= targetText.length) {
      _completeAssistantAnimation(itemId);
    }
  }

  void _completeAssistantAnimation(String itemId) {
    final animation = _assistantAnimations.remove(itemId);
    if (animation == null) return;
    animation.cancel();
    animation.showFinal();
    if (mounted) {
      setState(() {});
      _disposeAssistantAnimationAfterFrame(animation);
    } else {
      animation.dispose();
    }
  }

  bool _finishAssistantAnimations() {
    if (_assistantAnimations.isEmpty) return false;
    final animations = _assistantAnimations.values.toList();
    _assistantAnimations.clear();
    for (final animation in animations) {
      animation.cancel();
      animation.showFinal();
    }
    if (mounted) {
      setState(() {});
      for (final animation in animations) {
        _disposeAssistantAnimationAfterFrame(animation);
      }
    } else {
      for (final animation in animations) {
        animation.dispose();
      }
    }
    return true;
  }

  void _removeAssistantAnimation(String itemId) {
    final animation = _assistantAnimations.remove(itemId);
    if (animation == null) return;
    animation.cancel();
    _disposeAssistantAnimationAfterFrame(animation);
  }

  void _clearAssistantAnimations({bool deferDispose = true}) {
    if (_assistantAnimations.isEmpty) return;
    final animations = _assistantAnimations.values.toList();
    _assistantAnimations.clear();
    for (final animation in animations) {
      animation.cancel();
      if (deferDispose && mounted) {
        _disposeAssistantAnimationAfterFrame(animation);
      } else {
        animation.dispose();
      }
    }
  }

  void _disposeAssistantAnimationAfterFrame(
    _AssistantMessageAnimation animation,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      animation.dispose();
    });
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _upsertItem(ChatItem item) {
    final existingIndex =
        _items.indexWhere((existing) => existing.id == item.id);
    if (existingIndex >= 0) {
      _items = _items
          .map((existing) => existing.id == item.id ? item : existing)
          .toList();
    } else {
      _items = [..._items, item];
    }
  }

  void _toggleExpanded(String id) {
    setState(() {
      if (!_expandedMessageIds.add(id)) {
        _expandedMessageIds.remove(id);
      }
    });
  }

  void _openFilePreview(FileReference reference) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FilePreviewScreen(
          sessionId: widget.session.sessionId,
          reference: reference,
        ),
      ),
    );
  }

  void _openFileList() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FileListScreen(
          sessionId: widget.session.sessionId,
        ),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      if (_showJumpToBottom && mounted) {
        setState(() => _showJumpToBottom = false);
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _handleScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels < 160 &&
        _scrollController.position.userScrollDirection ==
            ScrollDirection.forward &&
        _hasMoreHistory &&
        !_isLoadingHistory) {
      unawaited(_loadEarlierMessages());
    }
    if (!_showJumpToBottom || !_isNearBottom()) return;
    setState(() => _showJumpToBottom = false);
  }

  bool get _showHistoryHeader => _hasMoreHistory || _isLoadingHistory;

  bool get _isThinking {
    final state = (_session ?? widget.session).state;
    if (state != SessionState.thinking) return false;
    if (_pendingApproval != null || _isLoading) return false;
    return _items.isEmpty || _items.last.role == ChatItemRole.user;
  }

  bool get _hasTrailingItem => _pendingApproval != null || _isThinking;

  Future<void> _loadEarlierMessages() async {
    if (_isLoadingHistory || !_hasMoreHistory) return;
    _finishAssistantAnimations();
    final before = _historyBefore;
    if (before == null) {
      setState(() => _hasMoreHistory = false);
      return;
    }

    final oldMaxExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final oldPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;

    setState(() {
      _isLoadingHistory = true;
      _error = null;
    });

    try {
      final page = await context.read<BridgeClient>().listMessages(
            sessionId: widget.session.sessionId,
            before: before,
            limit: 50,
          );
      if (!mounted) return;
      final existingIds = _items.map((item) => item.id).toSet();
      final older = page.items
          .where((item) => item.id.isEmpty || !existingIds.contains(item.id))
          .toList();
      setState(() {
        _items = [...older, ..._items];
        _hasMoreHistory = page.hasMore;
        _historyBefore = page.nextBefore;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final delta = _scrollController.position.maxScrollExtent - oldMaxExtent;
        final target = (oldPixels + delta)
            .clamp(
              _scrollController.position.minScrollExtent,
              _scrollController.position.maxScrollExtent,
            )
            .toDouble();
        _scrollController.jumpTo(target);
      });
    } on BridgeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < 96;
  }

  bool _isMessageEvent(String kind) {
    return kind == 'assistant_message' ||
        kind == 'user_message' ||
        kind == 'approval_requested';
  }

  String? _inputHint(SessionState state) {
    switch (state) {
      case SessionState.ready:
        return null;
      case SessionState.thinking:
        return 'Assistant is working. You can interrupt or wait.';
      case SessionState.approval:
        return 'Use the approval buttons, or type a reply if the CLI is asking for one.';
      case SessionState.choosing:
        return _pendingApproval?.choices.isNotEmpty == true
            ? 'Tap a choice above, or type a custom reply.'
            : 'Type your choice and send it.';
      case SessionState.error:
        return 'Session is in error. Refresh or start a new session.';
      case SessionState.ended:
        return 'Session has ended.';
      case SessionState.unknown:
        return 'Session state is unknown. Refresh before sending.';
    }
  }

  bool _canSendText(SessionState state) {
    return state == SessionState.ready ||
        state == SessionState.approval ||
        state == SessionState.choosing;
  }

  String _textFieldHint(SessionState state) {
    switch (state) {
      case SessionState.approval:
      case SessionState.choosing:
        return 'Reply to prompt';
      default:
        return 'Send prompt';
    }
  }
}

class _AssistantMessageAnimation {
  _AssistantMessageAnimation({
    required String displayedText,
    required this.targetText,
  }) : frame = ValueNotifier<_AssistantMessageFrame>(
          _AssistantMessageFrame(
            text: displayedText,
            isAnimating: true,
          ),
        );

  final ValueNotifier<_AssistantMessageFrame> frame;
  String targetText;
  Timer? timer;

  String get displayedText => frame.value.text;

  void cancel() {
    timer?.cancel();
    timer = null;
  }

  void showFinal() {
    frame.value = _AssistantMessageFrame(
      text: targetText,
      isAnimating: false,
    );
  }

  void dispose() {
    cancel();
    frame.dispose();
  }
}

class _AssistantMessageFrame {
  const _AssistantMessageFrame({
    required this.text,
    required this.isAnimating,
  });

  final String text;
  final bool isAnimating;
}

int _nextAssistantChunkEnd(String text, int start) {
  final remaining = text.length - start;
  final chunkUnits = switch (remaining) {
    > 1600 => 48,
    > 600 => 28,
    > 160 => 14,
    _ => 5,
  };
  final softLimit = chunkUnits + 8;

  var end = start;
  var units = 0;
  while (end < text.length && units < chunkUnits) {
    end = _nextRuneOffset(text, end);
    units++;
  }
  while (end < text.length &&
      units < softLimit &&
      !_isAssistantChunkBoundary(text.codeUnitAt(end - 1))) {
    end = _nextRuneOffset(text, end);
    units++;
  }
  return end;
}

int _nextRuneOffset(String text, int offset) {
  final codeUnit = text.codeUnitAt(offset);
  final isHighSurrogate = codeUnit >= 0xd800 && codeUnit <= 0xdbff;
  if (isHighSurrogate && offset + 1 < text.length) {
    return offset + 2;
  }
  return offset + 1;
}

bool _isAssistantChunkBoundary(int codeUnit) {
  return codeUnit == 0x09 ||
      codeUnit == 0x0a ||
      codeUnit == 0x20 ||
      codeUnit == 0x2c ||
      codeUnit == 0x2e ||
      codeUnit == 0x3a ||
      codeUnit == 0x3b ||
      codeUnit == 0x3002 ||
      codeUnit == 0xff0c;
}

class _PendingImageAttachment {
  const _PendingImageAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
  });

  final String name;
  final String mime;
  final Uint8List bytes;
}

class _PendingImageStrip extends StatelessWidget {
  const _PendingImageStrip({
    required this.images,
    required this.onRemove,
  });

  final List<_PendingImageAttachment> images;
  final ValueChanged<_PendingImageAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final image = images[index];
          return Container(
            width: 220,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(
                    image.bytes,
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        image.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        formatBytes(image.bytes.length),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove image',
                  icon: const Icon(Icons.close),
                  onPressed: () => onRemove(image),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HistoryLoader extends StatelessWidget {
  const _HistoryLoader({
    required this.isLoading,
    required this.onPressed,
  });

  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextButton.icon(
          icon: isLoading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history),
          label: Text(
              isLoading ? 'Loading earlier messages' : 'Load earlier messages'),
          onPressed: isLoading ? null : onPressed,
        ),
      ),
    );
  }
}

/// One-shot entrance: fade + 8px slide-up, played once when [animate] is true
/// on first build. Layout-neutral (Opacity + Transform.translate only), so it
/// never moves heights or disturbs the list's scroll math.
class _EntranceFade extends StatefulWidget {
  const _EntranceFade({required this.child, required this.animate});

  final Widget child;
  final bool animate;

  @override
  State<_EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<_EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: widget.animate ? 0.0 : 1.0,
    );
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.value == 1.0) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.sessionId,
    required this.item,
    this.animation,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenFile,
    this.onRetry,
    this.onFeedback,
  });

  static const double _collapsedMaxHeight = 280;

  final String sessionId;
  final ChatItem item;
  final _AssistantMessageAnimation? animation;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<FileReference> onOpenFile;
  final VoidCallback? onRetry;
  final VoidCallback? onFeedback;

  @override
  Widget build(BuildContext context) {
    final animation = this.animation;
    if (animation != null) {
      return ValueListenableBuilder<_AssistantMessageFrame>(
        valueListenable: animation.frame,
        builder: (context, frame, _) {
          return _buildBubble(context, frame);
        },
      );
    }
    return _buildBubble(context, null);
  }

  Widget _buildBubble(BuildContext context, _AssistantMessageFrame? frame) {
    final isUser = item.role == ChatItemRole.user;
    final isAnimating = frame?.isAnimating ?? false;
    final displayText = frame?.text ?? item.text;
    final isCollapsible = !isAnimating && _isCollapsible(displayText);
    final colorScheme = Theme.of(context).colorScheme;
    final background = isUser
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHigh;
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final content = _BubbleContent(
      child: isAnimating
          ? _PlainMessage(key: const ValueKey('plain'), text: displayText)
          : _MarkdownMessage(
              key: const ValueKey('md'),
              sessionId: sessionId,
              text: displayText,
              onOpenFile: onOpenFile,
            ),
    );

    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MessageBody(
                    collapsed: isCollapsible && !expanded,
                    background: background,
                    child: content,
                  ),
                  if (isCollapsible) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Icon(
                        expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                      ),
                      label: Text(expanded ? 'Collapse' : 'Show full response'),
                      onPressed: onToggleExpanded,
                    ),
                  ],
                  if (onFeedback != null) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: colorScheme.onSurfaceVariant,
                          textStyle: Theme.of(context).textTheme.labelSmall,
                        ),
                        icon: const Icon(Icons.flag_outlined, size: 14),
                        label: const Text('Report format issue'),
                        onPressed: onFeedback,
                      ),
                    ),
                  ],
                  if (item.pending || item.failed) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.failed ? Icons.error_outline : Icons.schedule,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.failed ? 'failed' : 'sending',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        if (item.failed && onRetry != null) ...[
                          const SizedBox(width: 8),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Retry'),
                            onPressed: onRetry,
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isCollapsible(String text) {
    return text.length > 800 ||
        '\n'.allMatches(text).length >= 12 ||
        text.contains('```');
  }
}

class _FeedbackResult {
  const _FeedbackResult({required this.verdict, this.note});

  final String verdict;
  final String? note;
}

const List<({String value, String label})> _feedbackVerdicts = [
  (value: 'format_error', label: 'Formatting is wrong'),
  (value: 'wrong_role', label: 'Wrong sender (user/assistant mixed up)'),
  (value: 'missing_content', label: 'Content missing or cut off'),
  (value: 'garbled', label: 'Garbled / encoding issue'),
  (value: 'choice_misparse', label: 'Options not detected'),
  (value: 'render_issue', label: 'Markdown renders wrong'),
  (value: 'good', label: 'Parsed well (good example)'),
  (value: 'other', label: 'Other'),
];

class _FeedbackSheet extends StatefulWidget {
  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  String? _verdict;
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Report this message', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tell us what looks wrong. We save the raw output to fix parsing.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final verdict in _feedbackVerdicts)
                  ChoiceChip(
                    label: Text(verdict.label),
                    selected: _verdict == verdict.value,
                    onSelected: (_) => setState(() => _verdict = verdict.value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _verdict == null
                    ? null
                    : () => Navigator.of(context).pop(
                          _FeedbackResult(
                            verdict: _verdict!,
                            note: _noteController.text,
                          ),
                        ),
                child: const Text('Submit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mid-stream rendering of an assistant message: plain text plus a blinking
/// amber "liveWire" caret meaning the remote machine is still typing. Only
/// built while the bubble is animating, so the caret disappears on its own when
/// the message completes (the bubble re-renders as markdown). The 40ms stream
/// loop is untouched — this is a sibling blink controller, fade-only.
class _PlainMessage extends StatefulWidget {
  const _PlainMessage({super.key, required this.text});

  final String text;

  @override
  State<_PlainMessage> createState() => _PlainMessageState();
}

class _PlainMessageState extends State<_PlainMessage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1060),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final caretHeight = (style?.fontSize ?? 14) * 1.15;
    final caret = Container(
      width: 2,
      height: caretHeight,
      margin: const EdgeInsets.only(left: 1),
      color: context.tokens.liveWire,
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: widget.text),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: CcmMotion.reduceMotionOf(context)
                ? caret
                : FadeTransition(
                    opacity: Tween<double>(begin: 0.15, end: 1).animate(
                      CurvedAnimation(parent: _blink, curve: Curves.easeInOut),
                    ),
                    child: caret,
                  ),
          ),
        ],
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.child,
    required this.collapsed,
    required this.background,
  });

  final Widget child;
  final bool collapsed;
  final Color background;

  @override
  Widget build(BuildContext context) {
    if (!collapsed) return child;

    return SizedBox(
      height: _ChatBubble._collapsedMaxHeight,
      child: ClipRect(
        child: Stack(
          children: [
            OverflowBox(
              alignment: Alignment.topLeft,
              maxHeight: double.infinity,
              child: child,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        background.withValues(alpha: 0),
                        background,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Crossfades the bubble body when it swaps from the streaming plain text to
/// the final markdown. The first build is instant (Duration.zero) so scroll
/// recycling never flickers historical bubbles in — only the in-place
/// plain→markdown key change animates.
class _BubbleContent extends StatefulWidget {
  const _BubbleContent({required this.child});

  final Widget child;

  @override
  State<_BubbleContent> createState() => _BubbleContentState();
}

class _BubbleContentState extends State<_BubbleContent> {
  bool _first = true;

  @override
  Widget build(BuildContext context) {
    if (_first) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _first = false);
      });
    }
    final duration = _first || CcmMotion.reduceMotionOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return AnimatedSwitcher(
      duration: duration,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: widget.child,
    );
  }
}

class _MarkdownMessage extends StatefulWidget {
  const _MarkdownMessage({
    super.key,
    required this.text,
    this.sessionId,
    this.onOpenFile,
  });

  final String text;
  final String? sessionId;
  final ValueChanged<FileReference>? onOpenFile;

  @override
  State<_MarkdownMessage> createState() => _MarkdownMessageState();
}

class _MarkdownMessageState extends State<_MarkdownMessage> {
  late Future<List<FileReference>> _resolvedFileReferences;

  @override
  void initState() {
    super.initState();
    _resolvedFileReferences = _resolveFileReferences();
  }

  @override
  void didUpdateWidget(_MarkdownMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.sessionId != widget.sessionId) {
      _resolvedFileReferences = _resolveFileReferences();
    }
  }

  Future<List<FileReference>> _resolveFileReferences() {
    final sessionId = widget.sessionId;
    if (sessionId == null) return Future.value(const <FileReference>[]);
    final references = extractFileReferences(widget.text);
    if (references.isEmpty) return Future.value(const <FileReference>[]);
    return context.read<BridgeClient>().resolveFileReferences(
          sessionId: sessionId,
          references: references,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium;
    final codeStyle = bodyStyle?.copyWith(
      fontFamily: context.type.monoFamily,
      backgroundColor: colorScheme.surfaceContainerHighest,
    );

    return FutureBuilder<List<FileReference>>(
      future: _resolvedFileReferences,
      builder: (context, snapshot) {
        final fileReferences = snapshot.data ?? const <FileReference>[];
        return MarkdownBody(
          data: _withInlineLinks(widget.text, fileReferences),
          selectable: true,
          onTapLink: (_, href, __) {
            _openMarkdownLink(href, fileReferences, widget.onOpenFile);
          },
          softLineBreak: true,
          builders: {
            'pre': _CodeBlockBuilder(
              colorScheme: colorScheme,
              codeStyle: codeStyle,
            ),
          },
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            a: bodyStyle?.copyWith(
              color: colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
            p: bodyStyle,
            pPadding: const EdgeInsets.only(bottom: 6),
            blockSpacing: 8,
            listIndent: 20,
            code: codeStyle,
            blockquotePadding: const EdgeInsets.only(left: 10),
            blockquoteDecoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 3,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

const _fileHrefPrefix = 'ccm-file:';

final RegExp _bareUrlPattern = RegExp(
  r'https?://[^\s<>\]]+',
  caseSensitive: false,
);

String _withInlineLinks(String input, List<FileReference> fileReferences) {
  final replacements = <_LinkReplacement>[];

  for (final match in _bareUrlPattern.allMatches(input)) {
    if (_isInsideExistingMarkdownLink(input, match.start)) continue;

    final rawUrl = match.group(0);
    if (rawUrl == null) continue;

    final trimmed = _trimUrlSuffix(rawUrl);
    final uri = Uri.tryParse(trimmed.url);
    if (uri == null || !uri.hasScheme) continue;

    replacements.add(_LinkReplacement(
      start: match.start,
      end: match.end,
      text:
          '[${_escapeMarkdownLabel(_readableLinkLabel(uri))}](${trimmed.url})${trimmed.suffix}',
    ));
  }

  for (final match in extractFileReferenceMatches(input)) {
    if (_isInsideExistingMarkdownLink(input, match.start)) continue;
    final reference = _fileReferenceForPath(match.path, fileReferences);
    if (reference == null) continue;

    replacements.add(_LinkReplacement(
      start: match.start,
      end: match.end,
      text:
          '[${_escapeMarkdownLabel(match.rawText)}]($_fileHrefPrefix${Uri.encodeComponent(reference.path)})',
    ));
  }

  if (replacements.isEmpty) return input;
  replacements.sort((a, b) => a.start.compareTo(b.start));

  final buffer = StringBuffer();
  var cursor = 0;

  for (final replacement in replacements) {
    if (replacement.start < cursor) continue;
    buffer
      ..write(input.substring(cursor, replacement.start))
      ..write(replacement.text);
    cursor = replacement.end;
  }

  buffer.write(input.substring(cursor));
  return buffer.toString();
}

class _LinkReplacement {
  const _LinkReplacement({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}

bool _isInsideExistingMarkdownLink(String input, int start) {
  if (start > 0 && input[start - 1] == '<') return true;
  final labelStart = input.lastIndexOf('[', start);
  if (labelStart >= 0) {
    final labelEnd = input.indexOf('](', labelStart);
    if (labelEnd >= start) return true;
    if (labelEnd >= 0) {
      final destinationEnd = input.indexOf(')', labelEnd + 2);
      if (destinationEnd >= start) return true;
    }
  }
  return false;
}

({String url, String suffix}) _trimUrlSuffix(String rawUrl) {
  var url = rawUrl;
  var suffix = '';
  const punctuation = '.,;:!?';

  while (url.isNotEmpty && punctuation.contains(url[url.length - 1])) {
    suffix = '${url[url.length - 1]}$suffix';
    url = url.substring(0, url.length - 1);
  }

  return (url: url, suffix: suffix);
}

String _readableLinkLabel(Uri uri) {
  final host = uri.host.isEmpty ? uri.toString() : uri.host;
  final path =
      uri.pathSegments.where((segment) => segment.isNotEmpty).take(2).join('/');
  final label = path.isEmpty ? host : '$host/$path';
  if (label.length <= 52) return label;
  return '${label.substring(0, 49)}...';
}

String _escapeMarkdownLabel(String input) {
  return input
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
}

void _openMarkdownLink(
  String? href,
  List<FileReference> fileReferences,
  ValueChanged<FileReference>? onOpenFile,
) {
  if (href == null || href.trim().isEmpty) return;
  final fileReference = _fileReferenceForHref(href, fileReferences);
  if (fileReference != null && onOpenFile != null) {
    onOpenFile(fileReference);
    return;
  }

  final uri = Uri.tryParse(href);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  unawaited(
      _linkChannel.invokeMethod<void>('openUrl', {'url': uri.toString()}));
}

FileReference? _fileReferenceForHref(
  String href,
  List<FileReference> references,
) {
  if (href.startsWith(_fileHrefPrefix)) {
    return _fileReferenceForPath(
      Uri.decodeComponent(href.substring(_fileHrefPrefix.length)),
      references,
    );
  }
  return _fileReferenceForPath(href, references);
}

FileReference? _fileReferenceForPath(
  String path,
  List<FileReference> references,
) {
  final normalized = _normalizeReferencePath(path);
  if (normalized.isEmpty) return null;

  for (final reference in references) {
    final paths = <String>{
      reference.path,
      if (reference.relativePath != null) reference.relativePath!,
      reference.name,
    }.map(_normalizeReferencePath);
    if (paths.contains(normalized)) return reference;
  }

  return null;
}

String _normalizeReferencePath(String path) {
  var normalized = Uri.decodeComponent(path.trim()).replaceAll('\\', '/');
  while (normalized.startsWith('./')) {
    normalized = normalized.substring(2);
  }
  return normalized;
}

IconData _fileIcon(FileReference file) {
  if (file.isMarkdown) return Icons.description_outlined;
  switch (file.language) {
    case 'json':
    case 'yaml':
    case 'toml':
    case 'xml':
    case 'dotenv':
      return Icons.tune;
    case 'csv':
      return Icons.table_chart_outlined;
    default:
      return Icons.code;
  }
}

String _fileSubtitle(FileReference file) {
  final size = file.bytes == null ? null : formatBytes(file.bytes!);
  if (size == null) return file.language;
  return '${file.language} · $size';
}

class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble();

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static double _dotOpacity(double t, int index) {
    final phase = (t - index / 3.0 + 1.0) % 1.0;
    if (phase < 0.25) return 0.25 + 0.75 * (phase / 0.25);
    if (phase < 0.5) return 1.0 - 0.75 * ((phase - 0.25) / 0.25);
    return 0.25;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // liveWire (dim): the thinking dots mean the remote machine is working.
    final dotColor = context.tokens.liveWireDim;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (index) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor.withValues(
                        alpha: _dotOpacity(_controller.value, index),
                      ),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CopyCodeButton extends StatefulWidget {
  const _CopyCodeButton({required this.text});

  final String text;

  @override
  State<_CopyCodeButton> createState() => _CopyCodeButtonState();
}

class _CopyCodeButtonState extends State<_CopyCodeButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _copied ? 'Copied!' : 'Copy code',
      icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
      visualDensity: VisualDensity.compact,
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.colorScheme, required this.codeStyle});

  final ColorScheme colorScheme;
  final TextStyle? codeStyle;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent.trimRight();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(code, style: codeStyle),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: _CopyCodeButton(text: code),
          ),
        ],
      ),
    );
  }
}
