import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../sessions/session_controller.dart';

class ApprovalNotificationController with WidgetsBindingObserver {
  ApprovalNotificationController({
    required BridgeClient client,
    required SessionController sessions,
    FlutterLocalNotificationsPlugin? notifications,
  })  : _client = client,
        _sessions = sessions,
        _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _channelId = 'approval_requests';
  static const _channelName = 'Approval requests';
  static const _channelDescription = 'Notifications for ccm approval requests.';
  static const _notificationIcon = 'ic_stat_approval';

  final BridgeClient _client;
  final SessionController _sessions;
  final FlutterLocalNotificationsPlugin _notifications;
  final Map<String, int> _notificationIdsByApproval = <String, int>{};

  StreamSubscription<BridgeEventEnvelope>? _eventSubscription;
  Future<void>? _initializeFuture;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _permissionRequested = false;
  bool _isDisposed = false;

  Future<void> initialize() {
    if (_isDisposed) return Future<void>.value();
    final existing = _initializeFuture;
    if (existing != null) return existing;

    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _eventSubscription = _client.events.listen(_handleEvent);
    _initializeFuture = _initializeNotifications().catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('Could not initialize approval notifications: $error');
      },
    );
    return _initializeFuture!;
  }

  Future<void> requestPermissionIfNeeded() async {
    if (_permissionRequested) return;
    _permissionRequested = true;

    try {
      await initialize();
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (error) {
      debugPrint('Could not request notification permission: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(_cancelAllApprovalNotifications());
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_eventSubscription?.cancel());
    unawaited(_cancelAllApprovalNotifications());
  }

  Future<void> _initializeNotifications() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings(_notificationIcon),
    );
    await _notifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  void _handleEvent(BridgeEventEnvelope envelope) {
    final event = envelope.event;
    switch (event.kind) {
      case 'approval_requested':
        if (_lifecycleState == AppLifecycleState.resumed) return;
        final approval = _approvalFromEvent(envelope);
        unawaited(_showApprovalNotification(envelope, approval));
        break;
      case 'approval_resolved':
        final approvalId = _approvalIdFromResolvedEvent(event.payload);
        if (approvalId == null || approvalId.isEmpty) {
          unawaited(_cancelSessionNotifications(envelope.sessionId));
        } else {
          unawaited(
            _cancelApprovalNotification(envelope.sessionId, approvalId),
          );
        }
        break;
      default:
        break;
    }
  }

  PendingApproval _approvalFromEvent(BridgeEventEnvelope envelope) {
    final rawApproval = envelope.event.payload['approval'];
    return PendingApproval.fromJson(
      rawApproval is Map
          ? Map<String, Object?>.from(rawApproval)
          : envelope.event.payload,
    );
  }

  Future<void> _showApprovalNotification(
    BridgeEventEnvelope envelope,
    PendingApproval approval,
  ) async {
    await initialize();
    if (_isDisposed || _lifecycleState == AppLifecycleState.resumed) return;

    final sessionId = approval.sessionId.isNotEmpty
        ? approval.sessionId
        : envelope.sessionId;
    final approvalId = approval.approvalId.isNotEmpty
        ? approval.approvalId
        : 'seq_${envelope.seq}';
    final key = _approvalNotificationKey(sessionId, approvalId);
    final id = _notificationIdsByApproval.putIfAbsent(
      key,
      () => _notificationIdFor(key),
    );
    final sessionName = _sessionNameFor(sessionId);
    final body = _notificationBody(approval);
    final payload = jsonEncode({
      'sessionId': sessionId,
      'approvalId': approvalId,
    });

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'Approval requested',
    );
    try {
      await _notifications.show(
        id,
        '$sessionName needs approval',
        body,
        const NotificationDetails(android: androidDetails),
        payload: payload,
      );
    } catch (error) {
      debugPrint('Could not show approval notification: $error');
    }
  }

  String _sessionNameFor(String sessionId) {
    final sessionName = _sessions.sessionById(sessionId)?.name.trim();
    if (sessionName != null && sessionName.isNotEmpty) return sessionName;
    return sessionId.isEmpty ? 'Session' : sessionId;
  }

  String _notificationBody(PendingApproval approval) {
    final description = approval.description.trim();
    if (description.isEmpty) {
      return '${approval.operationKind}: Approval requested';
    }
    return '${approval.operationKind}: $description';
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final data = Map<String, Object?>.from(decoded);
      final sessionId = data['sessionId'] as String?;
      final approvalId = data['approvalId'] as String?;
      if (sessionId == null || approvalId == null) return;
      unawaited(_cancelApprovalNotification(sessionId, approvalId));
    } catch (_) {
      // Invalid payloads should not prevent the app from opening.
    }
  }

  Future<void> _cancelApprovalNotification(
    String sessionId,
    String approvalId,
  ) async {
    final key = _approvalNotificationKey(sessionId, approvalId);
    final notificationId = _notificationIdsByApproval.remove(key);
    if (notificationId == null) return;
    await _cancelNotificationId(notificationId);
  }

  Future<void> _cancelSessionNotifications(String sessionId) async {
    final entries = _notificationIdsByApproval.entries
        .where((entry) => entry.key.startsWith('$sessionId\x00'))
        .toList();
    for (final entry in entries) {
      _notificationIdsByApproval.remove(entry.key);
      await _cancelNotificationId(entry.value);
    }
  }

  Future<void> _cancelAllApprovalNotifications() async {
    final ids = _notificationIdsByApproval.values.toList();
    _notificationIdsByApproval.clear();
    for (final id in ids) {
      await _cancelNotificationId(id);
    }
  }

  Future<void> _cancelNotificationId(int notificationId) async {
    try {
      await _notifications.cancel(notificationId);
    } catch (error) {
      debugPrint('Could not cancel approval notification: $error');
    }
  }

  String? _approvalIdFromResolvedEvent(Map<String, Object?> payload) {
    return payload['approvalId'] as String? ??
        payload['approval_id'] as String?;
  }

  String _approvalNotificationKey(String sessionId, String approvalId) {
    return '$sessionId\x00$approvalId';
  }

  int _notificationIdFor(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = 0x1fffffff & (hash + codeUnit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash == 0 ? 1 : hash;
  }
}
