import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../../core/utils/format_utils.dart';
import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../approvals/approval_card.dart';

const _linkChannel = MethodChannel('ccm_mobile/links');
const _mediaChannel = MethodChannel('ccm_mobile/media');
const _assistantStreamFrameDelay = Duration(milliseconds: 40);

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
                              return _ChatBubble(
                                key: ValueKey(item.id),
                                sessionId: widget.session.sessionId,
                                item: item,
                                animation: _assistantAnimations[item.id],
                                expanded: _expandedMessageIds.contains(item.id),
                                onToggleExpanded: () =>
                                    _toggleExpanded(item.id),
                                onOpenFile: _openFilePreview,
                                onRetry: item.failed && !_isSending
                                    ? () => _retryFailedMessage(item)
                                    : null,
                              );
                            }

                            if (_pendingApproval != null) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: ApprovalCard(
                                  approval: _pendingApproval!,
                                  isSubmitting: _isApproving,
                                  onAction: _approve,
                                ),
                              );
                            }
                            return const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: _ThinkingBubble(),
                            );
                          },
                        ),
                        if (_showJumpToBottom)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: Center(
                              child: FilledButton.tonalIcon(
                                icon: const Icon(Icons.keyboard_arrow_down),
                                label: const Text('New messages'),
                                onPressed: _scrollToBottom,
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
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Attach image',
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: canAttachImages ? _pickImage : null,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          enabled: canSend,
                          minLines: 1,
                          maxLines: 5,
                          decoration: InputDecoration(
                            hintText: textFieldHint,
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => canSend ? _send() : null,
                        ),
                      ),
                      const SizedBox(width: 8),
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
        _items = _items.where((item) => item.id != clientMessageId).toList();
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

  int _assistantSnapshotIndex(ChatItem item) {
    final existingIndex =
        _items.indexWhere((existing) => existing.id == item.id);
    if (existingIndex >= 0) return existingIndex;
    if (!item.snapshot || _items.isEmpty) return -1;

    final lastIndex = _items.length - 1;
    final last = _items[lastIndex];
    if (last.role == ChatItemRole.assistant && last.snapshot) {
      return lastIndex;
    }
    return -1;
  }

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
        return 'Type your choice and send it.';
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

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    super.key,
    required this.sessionId,
    required this.item,
    this.animation,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenFile,
    this.onRetry,
  });

  static const double _collapsedMaxHeight = 280;

  final String sessionId;
  final ChatItem item;
  final _AssistantMessageAnimation? animation;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<FileReference> onOpenFile;
  final VoidCallback? onRetry;

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
    final content = isAnimating
        ? _PlainMessage(text: displayText)
        : _MarkdownMessage(
            sessionId: sessionId,
            text: displayText,
            onOpenFile: onOpenFile,
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
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
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

class _PlainMessage extends StatelessWidget {
  const _PlainMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: Theme.of(context).textTheme.bodyMedium,
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

class _MarkdownMessage extends StatefulWidget {
  const _MarkdownMessage({
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
      fontFamily: 'monospace',
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

class _FileListScreen extends StatefulWidget {
  const _FileListScreen({required this.sessionId});

  final String sessionId;

  @override
  State<_FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<_FileListScreen> {
  final _searchController = TextEditingController();
  late Future<List<FileReference>> _files;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _files = _loadFiles();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<FileReference>> _loadFiles() {
    return context.read<BridgeClient>().listFiles(
          sessionId: widget.sessionId,
        );
  }

  void _refresh() {
    setState(() {
      _files = _loadFiles();
    });
  }

  void _openFile(FileReference reference) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FilePreviewScreen(
          sessionId: widget.sessionId,
          reference: reference,
        ),
      ),
    );
  }

  List<FileReference> _filtered(List<FileReference> files) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return files;
    return files.where((file) {
      final label = file.relativePath ?? file.name;
      return '$label ${file.language}'.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search files',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: _searchController.clear,
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<FileReference>>(
              future: _files,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _FilePreviewError(
                    message: snapshot.error.toString(),
                    onRetry: _refresh,
                  );
                }

                final files = _filtered(snapshot.data ?? const []);
                if (files.isEmpty) {
                  return _EmptyFileList(
                    message: _query.trim().isEmpty
                        ? 'No markdown or code files found.'
                        : 'No matching files.',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    _refresh();
                    await _files;
                  },
                  child: ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: files.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return ListTile(
                        leading: Icon(_fileIcon(file)),
                        title: Text(
                          file.relativePath ?? file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_fileSubtitle(file)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openFile(file),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFileList extends StatelessWidget {
  const _EmptyFileList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilePreviewScreen extends StatefulWidget {
  const _FilePreviewScreen({
    required this.sessionId,
    required this.reference,
  });

  final String sessionId;
  final FileReference reference;

  @override
  State<_FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<_FilePreviewScreen> {
  late Future<FilePreview> _preview;

  @override
  void initState() {
    super.initState();
    _preview = context.read<BridgeClient>().readFile(
          sessionId: widget.sessionId,
          path: widget.reference.path,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reference.name),
      ),
      body: FutureBuilder<FilePreview>(
        future: _preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _FilePreviewError(
              message: snapshot.error.toString(),
              onRetry: () {
                setState(() {
                  _preview = context.read<BridgeClient>().readFile(
                        sessionId: widget.sessionId,
                        path: widget.reference.path,
                      );
                });
              },
            );
          }
          final preview = snapshot.data;
          if (preview == null) {
            return _FilePreviewError(
              message: 'File preview is empty.',
              onRetry: () {
                setState(() {
                  _preview = context.read<BridgeClient>().readFile(
                        sessionId: widget.sessionId,
                        path: widget.reference.path,
                      );
                });
              },
            );
          }
          return _FilePreviewBody(
            sessionId: widget.sessionId,
            preview: preview,
          );
        },
      ),
    );
  }
}

class _FilePreviewBody extends StatelessWidget {
  const _FilePreviewBody({
    required this.sessionId,
    required this.preview,
  });

  final String sessionId;
  final FilePreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  preview.relativePath,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${preview.language} · ${formatBytes(preview.bytes)}',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
        if (preview.truncated)
          Container(
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.all(8),
            child: const Text('Preview truncated because the file is large.'),
          ),
        Expanded(
          child: preview.isMarkdown
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _MarkdownMessage(
                    sessionId: sessionId,
                    text: preview.content,
                    onOpenFile: (reference) {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _FilePreviewScreen(
                            sessionId: sessionId,
                            reference: reference,
                          ),
                        ),
                      );
                    },
                  ),
                )
              : _CodePreview(content: preview.content),
        ),
      ],
    );
  }
}

class _CodePreview extends StatelessWidget {
  const _CodePreview({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            content,
            style: TextStyle(
              fontFamily: 'monospace',
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilePreviewError extends StatelessWidget {
  const _FilePreviewError({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
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
                      color: colorScheme.onSurfaceVariant.withValues(
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
