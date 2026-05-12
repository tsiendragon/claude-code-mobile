import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../approvals/approval_card.dart';

const _linkChannel = MethodChannel('ccm_mobile/links');
const _mediaChannel = MethodChannel('ccm_mobile/media');

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
  PendingApproval? _pendingApproval;
  bool _isLoading = true;
  bool _isLoadingHistory = false;
  bool _hasMoreHistory = false;
  bool _isSending = false;
  bool _isApproving = false;
  bool _hasEventGap = false;
  bool _showJumpToBottom = false;
  int? _historyBefore;
  String? _error;

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
  void dispose() {
    _eventSubscription?.cancel();
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
              '${sessionBackendLabel(session.backend)} · ${session.state.name}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        actions: [
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
                padding: const EdgeInsets.all(8),
                child:
                    const Text('Event history gap detected. Snapshot shown.'),
              ),
            if (_error != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.all(8),
                child: Text(_error!),
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
                              (_pendingApproval == null ? 0 : 1),
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
                                expanded: _expandedMessageIds.contains(item.id),
                                onToggleExpanded: () =>
                                    _toggleExpanded(item.id),
                                onOpenFile: _openFilePreview,
                              );
                            }

                            return Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: ApprovalCard(
                                approval: _pendingApproval!,
                                isSubmitting: _isApproving,
                                onAction: _approve,
                              ),
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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final snapshot = await context
          .read<BridgeClient>()
          .attachSession(widget.session.sessionId);
      setState(() {
        _session = snapshot.session;
        _items = snapshot.items;
        _hasMoreHistory = snapshot.hasMoreHistory;
        _historyBefore = snapshot.nextHistoryBefore;
        _expandedMessageIds
            .removeWhere((id) => !_items.any((item) => item.id == id));
        _pendingApproval = snapshot.pendingApproval;
        _hasEventGap = snapshot.hasEventGap;
        _showJumpToBottom = false;
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
          ));
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
      buffer.writeln('- ${image.name} (${_formatBytes(image.bytes.length)})');
    }
    return buffer.toString().trimRight();
  }

  void _handleEvent(BridgeEventEnvelope envelope) {
    if (envelope.sessionId != widget.session.sessionId || !mounted) return;

    final event = envelope.event;
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
          );
          break;
        case 'assistant_message':
          final item = ChatItem.fromAssistantEvent(envelope, event.payload);
          if (item.text.isNotEmpty) {
            _upsertItem(item);
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
        case 'event_gap':
          _hasEventGap = true;
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

  Future<void> _loadEarlierMessages() async {
    if (_isLoadingHistory || !_hasMoreHistory) return;
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
                        _formatBytes(image.bytes.length),
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
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenFile,
  });

  static const double _collapsedMaxHeight = 280;

  final String sessionId;
  final ChatItem item;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<FileReference> onOpenFile;

  @override
  Widget build(BuildContext context) {
    final isUser = item.role == ChatItemRole.user;
    final isCollapsible = _isCollapsible(item.text);
    final colorScheme = Theme.of(context).colorScheme;
    final background = isUser
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHigh;
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final content = _MarkdownMessage(
      sessionId: sessionId,
      text: item.text,
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
    return text.length > 1200 || '\n'.allMatches(text).length >= 18;
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
            SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
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
            codeblockPadding: const EdgeInsets.all(10),
            codeblockDecoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
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
                  '${preview.language} · ${_formatBytes(preview.bytes)}',
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

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}
