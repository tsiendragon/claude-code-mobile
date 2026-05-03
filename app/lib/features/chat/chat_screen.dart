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
  bool _isLoading = true;
  bool _isSending = false;
  bool _isApproving = false;
  bool _hasEventGap = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
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
    final canSend =
        (_canSendText(session.state) || _pendingApproval != null) && !_isSending;
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
                  Row(
                    children: [
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
                                child: CircularProgressIndicator(strokeWidth: 2),
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
      final snapshot =
          await context.read<BridgeClient>().attachSession(widget.session.sessionId);
      setState(() {
        _session = snapshot.session;
        _items = snapshot.items;
        _pendingApproval = snapshot.pendingApproval;
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
    final currentState = (_session ?? widget.session).state;
    final useCommand = _pendingApproval != null ||
        currentState == SessionState.approval ||
        currentState == SessionState.choosing;

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
      if (useCommand) {
        await context.read<BridgeClient>().sendCommand(
              sessionId: widget.session.sessionId,
              clientMessageId: clientMessageId,
              command: text,
            );
      } else {
        await context.read<BridgeClient>().sendMessage(
              sessionId: widget.session.sessionId,
              clientMessageId: clientMessageId,
              text: text,
            );
      }
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
    _scrollToBottom();
  }

  void _replaceItem(String id, ChatItem replacement) {
    if (!mounted) return;
    setState(() {
      _items = _items.map((item) => item.id == id ? replacement : item).toList();
    });
  }

  void _upsertItem(ChatItem item) {
    final existingIndex = _items.indexWhere((existing) => existing.id == item.id);
    if (existingIndex >= 0) {
      _items = _items
          .map((existing) => existing.id == item.id ? item : existing)
          .toList();
    } else {
      _items = [..._items, item];
    }
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
}
