import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../approvals/approval_card.dart';

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
  PendingApproval? _pendingApproval;
  String? _latestOutputSnapshot;
  int _lastSeq = 0;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isApproving = false;
  bool _hasEventGap = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _lastSeq = widget.session.lastSeq;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attach();
      final client = context.read<BridgeClient>();
      _eventSubscription = client.events.listen(_handleEvent);
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final canSend = session.state == SessionState.ready && !_isSending;
    final canInterrupt = session.state == SessionState.thinking ||
        session.state == SessionState.approval ||
        session.state == SessionState.choosing;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.name),
            Text(
              session.state.name,
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
                child: const Text('Event history gap detected. Snapshot shown.'),
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
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_latestOutputSnapshot != null &&
                            _latestOutputSnapshot!.isNotEmpty)
                          _SnapshotPanel(text: _latestOutputSnapshot!),
                        for (final item in _items) _ChatBubble(item: item),
                        if (_pendingApproval != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: ApprovalCard(
                              approval: _pendingApproval!,
                              isSubmitting: _isApproving,
                              onAction: _approve,
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: 'Send prompt',
                        border: OutlineInputBorder(),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }

  Future<void> _attach() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final snapshot =
          await context.read<BridgeClient>().attachSession(widget.session.sessionId);
      setState(() {
        _session = snapshot.session;
        _items = snapshot.items;
        _lastSeq = snapshot.lastSeq;
        _pendingApproval = snapshot.pendingApproval;
        _latestOutputSnapshot = snapshot.latestOutputSnapshot;
        _hasEventGap = snapshot.hasEventGap;
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
    if (text.isEmpty) return;

    final clientMessageId =
        'cmsg_${DateTime.now().microsecondsSinceEpoch.toString()}';
    final optimistic = ChatItem(
      id: clientMessageId,
      role: ChatItemRole.user,
      text: text,
      pending: true,
    );

    setState(() {
      _isSending = true;
      _items = [..._items, optimistic];
      _messageController.clear();
    });
    _scrollToBottom();

    try {
      await context.read<BridgeClient>().sendMessage(
            sessionId: widget.session.sessionId,
            clientMessageId: clientMessageId,
            text: text,
          );
      _replaceItem(clientMessageId, optimistic.copyWith(pending: false));
    } on BridgeException catch (error) {
      _replaceItem(clientMessageId, optimistic.copyWith(
        pending: false,
        failed: true,
      ));
      setState(() => _error = error.message);
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
      await context.read<BridgeClient>().approve(
            sessionId: approval.sessionId,
            approvalId: approval.approvalId,
            action: action,
            idempotencyKey:
                'idem_${approval.approvalId}_${DateTime.now().microsecondsSinceEpoch}',
          );
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

  void _handleEvent(BridgeEventEnvelope envelope) {
    if (envelope.sessionId != widget.session.sessionId || !mounted) return;

    final event = envelope.event;
    setState(() {
      _lastSeq = envelope.seq;
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
            if (item.snapshot) {
              _latestOutputSnapshot = item.text;
            } else {
              _items = [..._items, item];
            }
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
    _scrollToBottom();
  }

  void _replaceItem(String id, ChatItem replacement) {
    if (!mounted) return;
    setState(() {
      _items = _items.map((item) => item.id == id ? replacement : item).toList();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }
}

class _SnapshotPanel extends StatelessWidget {
  const _SnapshotPanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.article_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Latest output',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final isUser = item.role == ChatItemRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    final background =
        isUser ? colorScheme.primaryContainer : colorScheme.surfaceContainerHigh;
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;

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
                  SelectableText(item.text),
                  if (item.pending || item.failed || item.snapshot) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.failed
                              ? Icons.error_outline
                              : item.pending
                                  ? Icons.schedule
                                  : Icons.article_outlined,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.failed
                              ? 'failed'
                              : item.pending
                                  ? 'sending'
                                  : 'snapshot',
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
}
