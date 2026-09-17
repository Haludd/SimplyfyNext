import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/room_client_config.dart';
import '../contracts/translated_sign_utterance.dart';
import '../models/room_models.dart';
import 'room_session_storage.dart';
import 'translated_sign_utterance_gateway.dart';

typedef RoomSocketConnector = WebSocketChannel Function(Uri uri);

/// Owns one participant's credentials, ordering, recovery and room transport.
final class RoomSessionController extends ChangeNotifier
    implements TranslatedSignUtteranceGateway {
  RoomSessionController({
    required this.config,
    http.Client? httpClient,
    RoomSessionStorage? storage,
    RoomSocketConnector? socketConnector,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _storage = storage ?? RoomSessionStorage(),
       _socketConnector = socketConnector ?? WebSocketChannel.connect;

  final RoomClientConfig config;
  final http.Client _http;
  final bool _ownsHttp;
  final RoomSessionStorage _storage;
  final RoomSocketConnector _socketConnector;
  final Map<String, RoomMessage> _messages = <String, RoomMessage>{};
  final Map<String, RoomParticipant> _participants =
      <String, RoomParticipant>{};
  final Map<String, String> _activity = <String, String>{};
  final Set<String> _spokenTerminalMessages = <String>{};
  final List<RoomTransportTrace> _transportTrace = <RoomTransportTrace>[];

  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Timer? _terminalRecoveryTimer;
  String? _terminalRecoveryMessageId;
  int _terminalRecoveryAttempt = 0;
  RoomCredentials? _credentials;
  RoomConnectionStatus _status = RoomConnectionStatus.idle;
  String? _error;
  int _roomVersion = -1;
  int _contextVersion = 0;
  int _nextClientSequence = 0;
  int _reconnectAttempt = 0;
  bool _submissionInFlight = false;
  bool _disposed = false;
  Map<String, dynamic>? _pendingRequest;

  Future<void> Function(String text)? onIncomingSignedText;

  RoomCredentials? get credentials => _credentials;
  RoomConnectionStatus get status => _status;
  String? get error => _error;
  int get roomVersion => _roomVersion;
  int get contextVersion => _contextVersion;
  bool get hasRoom => _credentials != null;
  bool get isConnected => _status == RoomConnectionStatus.connected;
  bool get isSigner => _credentials?.role == RoomRole.signer;
  bool get isHearing => _credentials?.role == RoomRole.hearing;
  bool get submissionInFlight => _submissionInFlight;
  @override
  bool get hasPendingRetry => _pendingRequest != null;

  /// A short, in-memory-only record for the UI's transport inspector.
  /// It contains finalized room payloads and redacted backend events, never
  /// camera frames, landmarks, or participant credentials.
  List<RoomTransportTrace> get transportTrace =>
      List<RoomTransportTrace>.unmodifiable(_transportTrace);

  void clearTransportTrace() {
    if (_transportTrace.isEmpty) return;
    _transportTrace.clear();
    notifyListeners();
  }

  @override
  /// A signer may use a newly created room alone while testing the local
  /// camera-to-backend flow. A hearing participant can still join later.
  bool get isConfigured => isSigner && hasRoom;

  @override
  String? get configurationMessage => !hasRoom
      ? 'Create a signing room before sending an utterance.'
      : !isSigner
      ? 'Only the signing participant can send recognized sign words.'
      : null;

  @override
  int get nextClientSequence => _nextClientSequence;

  List<RoomMessage> get messages {
    final result = _messages.values.toList(growable: false)
      ..sort((a, b) => a.serverSequence.compareTo(b.serverSequence));
    return result;
  }

  List<RoomParticipant> get participants =>
      _participants.values.toList(growable: false);

  RoomParticipant? get partner {
    final ownId = _credentials?.participantId;
    for (final participant in _participants.values) {
      if (participant.id != ownId) return participant;
    }
    return null;
  }

  String? activityFor(String participantId) => _activity[participantId];

  Future<bool> restore() async {
    final stored = _storage.read();
    if (stored == null || stored.isEmpty) return false;
    try {
      final document = decodeRoomObject(stored);
      _credentials = RoomCredentials.fromJson(
        Map<String, dynamic>.from(document['credentials'] as Map),
      );
      _nextClientSequence = document['next_client_sequence'] as int? ?? 0;
      _pendingRequest = document['pending_request'] is Map
          ? Map<String, dynamic>.from(document['pending_request'] as Map)
          : null;
      await recover();
      await connect();
      return true;
    } on Object {
      await _finishLocally('Saved room could not be restored.');
      return false;
    }
  }

  Future<void> create(String alias) async {
    await _enter(alias: alias, joining: false);
  }

  Future<void> join(String alias, String code) async {
    await _enter(alias: alias, joining: true, code: code);
  }

  Future<void> _enter({
    required String alias,
    required bool joining,
    String? code,
  }) async {
    _status = joining
        ? RoomConnectionStatus.joining
        : RoomConnectionStatus.creating;
    _error = null;
    notifyListeners();
    try {
      final name = alias.trim();
      if (name.isEmpty || name.length > 40) {
        throw const RoomSessionException(
          'invalid_alias',
          'Enter a name up to 40 characters.',
        );
      }
      final payload = <String, dynamic>{
        'schema_version': '1.0',
        'event_schema_version': '1.0',
        'alias': name,
        if (joining) 'code': _normalizeCode(code ?? ''),
      };
      final response = await _request(
        joining ? '/v1/rooms/join' : '/v1/rooms',
        method: 'POST',
        body: payload,
        authenticated: false,
        acceptedStatuses: joining ? const <int>{200} : const <int>{201},
      );
      _credentials = RoomCredentials.fromJson(response);
      _messages.clear();
      _participants.clear();
      _activity.clear();
      _spokenTerminalMessages.clear();
      _roomVersion = -1;
      _contextVersion = 0;
      _nextClientSequence = 0;
      _pendingRequest = null;
      _persist();
      await connect();
    } on Object catch (failure) {
      _status = RoomConnectionStatus.error;
      _error = _messageFor(failure);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> connect() async {
    final current = _credentials;
    if (current == null || _disposed) return;
    await _closeSocket();
    _status = _reconnectAttempt == 0
        ? RoomConnectionStatus.connecting
        : RoomConnectionStatus.reconnecting;
    _error = null;
    notifyListeners();
    try {
      final channel = _socketConnector(
        config.websocket('/v1/rooms/${current.code}/events'),
      );
      _socket = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      if (_socket != channel || _disposed) return;
      final authentication = <String, dynamic>{
        'type': 'authenticate',
        'event_schema_version': '1.0',
        'token': current.token,
      };
      _recordTransport(
        direction: RoomTransportDirection.frontendToBackend,
        transport: 'websocket',
        label: 'authenticate',
        payload: authentication,
      );
      channel.sink.add(jsonEncode(authentication));
      _socketSubscription = channel.stream.listen(
        _onSocketData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );
      _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        if (_socket == channel && isConnected) {
          const ping = <String, dynamic>{'type': 'ping'};
          _recordTransport(
            direction: RoomTransportDirection.frontendToBackend,
            transport: 'websocket',
            label: 'ping',
            payload: ping,
          );
          channel.sink.add(jsonEncode(ping));
        }
      });
    } on Object catch (failure) {
      _error = _messageFor(failure);
      _scheduleReconnect();
    }
  }

  Future<void> recover() async {
    final current = _requireCredentials();
    final snapshot = await _request(
      '/v1/rooms/${current.code}',
      acceptedStatuses: const <int>{200},
    );
    _applySnapshot(snapshot);
  }

  @override
  Future<TranslatedSignUtteranceAcknowledgement> submit(
    TranslatedSignUtterance utterance,
  ) async {
    final current = _requireCredentials();
    if (current.role != RoomRole.signer) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'wrong_role',
        message: 'Only the signing participant can send sign words.',
      );
    }
    if (utterance.clientSequence > _nextClientSequence) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'sequence_conflict',
        message: 'Wait for the pending message before sending another.',
      );
    }
    if (_submissionInFlight) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'busy',
        message: 'A message is already being sent.',
        retryable: true,
      );
    }
    final body = utterance.toJson();
    try {
      _preparePending('sign', body);
    } on RoomSessionException catch (failure) {
      throw TranslatedSignUtteranceSubmissionException(
        code: failure.code,
        message: failure.message,
        retryable: failure.retryable,
      );
    }
    _submissionInFlight = true;
    notifyListeners();
    try {
      final response = await _request(
        '/v1/rooms/${current.code}/sign-utterances',
        method: 'POST',
        body: body,
        acceptedStatuses: const <int>{202},
      );
      final acknowledgement = TranslatedSignUtteranceAcknowledgement.fromJson(
        response,
        expectedMessageId: utterance.messageId,
        expectedClientSequence: utterance.clientSequence,
      );
      _completePending(acknowledgement.clientSequence);
      _scheduleTerminalRecovery(utterance.messageId);
      return acknowledgement;
    } on RoomSessionException catch (failure) {
      throw TranslatedSignUtteranceSubmissionException(
        code: failure.code,
        message: failure.message,
        retryable: failure.retryable,
      );
    } finally {
      _submissionInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<RoomMessage> sendText(String text, {String source = 'text'}) async {
    final current = _requireCredentials();
    final value = text.trim();
    if (value.isEmpty || value.length > 2000) {
      throw const RoomSessionException(
        'invalid_text',
        'Enter a message up to 2000 characters.',
      );
    }
    if (source != 'text' && source != 'speech') {
      throw const RoomSessionException(
        'invalid_source',
        'Unsupported message source.',
      );
    }
    if (_submissionInFlight || _pendingRequest != null) {
      throw const RoomSessionException(
        'busy',
        'Retry or finish the pending message first.',
        retryable: true,
      );
    }
    final body = <String, dynamic>{
      'schema_version': '1.0',
      'message_id': _uuidV4(),
      'client_sequence': _nextClientSequence,
      'source': source,
      'text': value,
    };
    _preparePending('text', body);
    _submissionInFlight = true;
    notifyListeners();
    try {
      final response = await _request(
        '/v1/rooms/${current.code}/messages',
        method: 'POST',
        body: body,
        acceptedStatuses: const <int>{200, 201},
      );
      final message = RoomMessage.fromJson(response);
      _messages[message.key] = message;
      _completePending(message.clientSequence);
      notifyListeners();
      return message;
    } finally {
      _submissionInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> retryPending() async {
    final pending = _pendingRequest;
    final current = _requireCredentials();
    if (pending == null || _submissionInFlight) return;
    final kind = pending['kind'];
    final rawBody = pending['body'];
    if (rawBody is! Map) {
      _pendingRequest = null;
      _persist();
      return;
    }
    final body = Map<String, dynamic>.from(rawBody);
    _submissionInFlight = true;
    notifyListeners();
    try {
      if (kind == 'sign') {
        final response = await _request(
          '/v1/rooms/${current.code}/sign-utterances',
          method: 'POST',
          body: body,
          acceptedStatuses: const <int>{202},
        );
        final acknowledgement = TranslatedSignUtteranceAcknowledgement.fromJson(
          response,
          expectedMessageId: body['message_id'] as String,
          expectedClientSequence: body['client_sequence'] as int,
        );
        _completePending(acknowledgement.clientSequence);
        _scheduleTerminalRecovery(acknowledgement.messageId);
      } else if (kind == 'text') {
        final response = await _request(
          '/v1/rooms/${current.code}/messages',
          method: 'POST',
          body: body,
          acceptedStatuses: const <int>{200, 201},
        );
        final message = RoomMessage.fromJson(response);
        _messages[message.key] = message;
        _completePending(message.clientSequence);
      }
    } finally {
      _submissionInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Future<void> retryPendingSubmission() async {
    try {
      await retryPending();
    } on RoomSessionException catch (failure) {
      throw TranslatedSignUtteranceSubmissionException(
        code: failure.code,
        message: failure.message,
        retryable: failure.retryable,
      );
    }
  }

  void sendActivity(String state) {
    if (!isConnected ||
        !const <String>{
          'idle',
          'typing',
          'listening',
          'signing',
        }.contains(state)) {
      return;
    }
    _socket?.sink.add(
      jsonEncode(<String, dynamic>{'type': 'activity', 'state': state}),
    );
    _recordTransport(
      direction: RoomTransportDirection.frontendToBackend,
      transport: 'websocket',
      label: 'activity',
      payload: <String, dynamic>{'type': 'activity', 'state': state},
    );
  }

  Future<void> end() async {
    final current = _credentials;
    if (current == null) return;
    try {
      await _request(
        '/v1/rooms/${current.code}',
        method: 'DELETE',
        acceptedStatuses: const <int>{204},
      );
    } on RoomSessionException catch (failure) {
      if (failure.code != 'room_unavailable') rethrow;
    } finally {
      await _finishLocally('Conversation ended.');
    }
  }

  Future<void> leaveLocal() =>
      _finishLocally('Conversation cleared on this device.');

  Uri invitationUri(Uri frontendOrigin) {
    final current = _requireCredentials();
    return frontendOrigin.replace(
      path: '/',
      queryParameters: <String, String>{'room': current.code},
      fragment: null,
    );
  }

  void _onSocketData(dynamic data) {
    try {
      final event = decodeRoomObject(data as String);
      _recordTransport(
        direction: RoomTransportDirection.backendToFrontend,
        transport: 'websocket',
        label: event['type'] as String? ?? 'event',
        payload: event,
      );
      if (event['event_schema_version'] != '1.0') {
        throw const FormatException('Unsupported room event schema');
      }
      final version = event['room_version'];
      if (version is! int || version < 0 || version < _roomVersion) return;
      switch (event['type']) {
        case 'snapshot':
          _applySnapshot(event);
          break;
        case 'message_upsert':
          final raw = event['message'];
          if (raw is! Map) throw const FormatException('Invalid message event');
          _roomVersion = version;
          _upsert(RoomMessage.fromJson(Map<String, dynamic>.from(raw)));
          break;
        case 'presence':
          final raw = event['participant'];
          if (raw is! Map) {
            throw const FormatException('Invalid presence event');
          }
          _roomVersion = version;
          final participant = RoomParticipant.fromJson(
            Map<String, dynamic>.from(raw),
          );
          _participants[participant.id] = participant;
          break;
        case 'activity':
          _roomVersion = version;
          _activity[event['participant_id'] as String] =
              event['state'] as String;
          break;
        case 'room_ended':
          unawaited(_finishLocally('The conversation ended.'));
          return;
        case 'error':
          _roomVersion = version;
          if (event['code'] == 'resync_required') {
            unawaited(_recoverAfterSocketFailure());
          }
          break;
        case 'pong':
          _roomVersion = version;
          break;
        default:
          throw const FormatException('Unsupported room event');
      }
      _status = RoomConnectionStatus.connected;
      _error = null;
      _reconnectAttempt = 0;
      notifyListeners();
      if (_pendingRequest != null && !_submissionInFlight) {
        unawaited(retryPending());
      }
    } on Object {
      _error = 'The room sent an unsupported event. Reconnecting…';
      unawaited(_recoverAfterSocketFailure());
    }
  }

  void _applySnapshot(Map<String, dynamic> event) {
    final version = event['room_version'];
    final context = event['context_version'];
    final rawParticipants = event['participants'];
    final rawMessages = event['messages'];
    if (version is! int ||
        context is! int ||
        rawParticipants is! List ||
        rawMessages is! List) {
      throw const FormatException('Invalid room snapshot');
    }
    _roomVersion = version;
    _contextVersion = context;
    _participants
      ..clear()
      ..addEntries(
        rawParticipants.map((raw) {
          final participant = RoomParticipant.fromJson(
            Map<String, dynamic>.from(raw as Map),
          );
          return MapEntry<String, RoomParticipant>(participant.id, participant);
        }),
      );
    _messages
      ..clear()
      ..addEntries(
        rawMessages.map((raw) {
          final message = RoomMessage.fromJson(
            Map<String, dynamic>.from(raw as Map),
          );
          return MapEntry<String, RoomMessage>(message.key, message);
        }),
      );
    _stopTerminalRecoveryIfComplete();
    final ownId = _credentials?.participantId;
    final ownMessages = _messages.values.where(
      (message) => message.senderId == ownId,
    );
    for (final message in ownMessages) {
      if (message.clientSequence >= _nextClientSequence) {
        _nextClientSequence = message.clientSequence + 1;
      }
    }
    _persist();
  }

  void _upsert(RoomMessage message) {
    final previous = _messages[message.key];
    _messages[message.key] = message;
    _contextVersion = max(_contextVersion, message.contextVersion);
    final ownId = _credentials?.participantId;
    if (message.senderId == ownId && _matchesPendingRequest(message)) {
      // A websocket event can arrive even when the HTTP acknowledgement was
      // lost. It proves the backend received the exact packet, so clear the
      // transport hold instead of leaving the signer in a stale send state.
      _completePending(message.clientSequence);
    }
    if (message.senderId == ownId &&
        message.clientSequence >= _nextClientSequence) {
      _nextClientSequence = message.clientSequence + 1;
      _persist();
    }
    if (previous?.isTerminal != true &&
        message.isTerminal &&
        message.status == 'accepted' &&
        message.source == 'sign' &&
        message.senderId != ownId &&
        _spokenTerminalMessages.add(message.key)) {
      final text = message.ttsText ?? message.text;
      if (text != null) unawaited(onIncomingSignedText?.call(text));
    }
    if (message.messageId == _terminalRecoveryMessageId && message.isTerminal) {
      _cancelTerminalRecovery();
    }
  }

  /// WebSocket delivery is primary. These sparse authenticated snapshots make
  /// a terminal sentence/repair visible even if a proxy silently drops one
  /// incremental event while leaving the socket open.
  void _scheduleTerminalRecovery(String messageId) {
    _terminalRecoveryTimer?.cancel();
    _terminalRecoveryMessageId = messageId;
    _terminalRecoveryAttempt = 0;
    _scheduleNextTerminalRecovery();
  }

  void _scheduleNextTerminalRecovery() {
    if (_disposed ||
        _credentials == null ||
        _terminalRecoveryMessageId == null) {
      return;
    }
    const delays = <Duration>[
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ];
    if (_terminalRecoveryAttempt >= delays.length) return;
    final delay = delays[_terminalRecoveryAttempt++];
    _terminalRecoveryTimer = Timer(
      delay,
      () => unawaited(_recoverTerminalMessage()),
    );
  }

  Future<void> _recoverTerminalMessage() async {
    final messageId = _terminalRecoveryMessageId;
    if (messageId == null || _disposed || _credentials == null) return;
    if (_hasTerminalMessage(messageId)) {
      _cancelTerminalRecovery();
      return;
    }
    try {
      await recover();
    } on Object {
      // Socket reconnect and the next bounded snapshot remain available.
    }
    if (_hasTerminalMessage(messageId) || _credentials == null) {
      _cancelTerminalRecovery();
    } else {
      _scheduleNextTerminalRecovery();
    }
  }

  bool _hasTerminalMessage(String messageId) => _messages.values.any(
    (message) => message.messageId == messageId && message.isTerminal,
  );

  void _stopTerminalRecoveryIfComplete() {
    final messageId = _terminalRecoveryMessageId;
    if (messageId != null && _hasTerminalMessage(messageId)) {
      _cancelTerminalRecovery();
    }
  }

  void _cancelTerminalRecovery() {
    _terminalRecoveryTimer?.cancel();
    _terminalRecoveryTimer = null;
    _terminalRecoveryMessageId = null;
    _terminalRecoveryAttempt = 0;
  }

  bool _matchesPendingRequest(RoomMessage message) {
    final pending = _pendingRequest;
    final body = pending?['body'];
    if (body is! Map) return false;
    return body['message_id'] == message.messageId &&
        body['client_sequence'] == message.clientSequence;
  }

  void _onSocketError(Object failure) {
    _error = 'Connection interrupted. Messages remain available for retry.';
    if (!_disposed) notifyListeners();
  }

  Future<void> _recoverAfterSocketFailure() async {
    try {
      await recover();
    } on RoomSessionException {
      if (_credentials != null) _scheduleReconnect();
    } on Object {
      _scheduleReconnect();
    }
  }

  void _onSocketDone() {
    if (_credentials == null ||
        _disposed ||
        _status == RoomConnectionStatus.ended) {
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_credentials == null ||
        _disposed ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    _status = RoomConnectionStatus.reconnecting;
    final seconds = min(10, 1 << min(_reconnectAttempt++, 3));
    notifyListeners();
    _reconnectTimer = Timer(
      Duration(seconds: seconds),
      () => unawaited(connect()),
    );
  }

  void _preparePending(String kind, Map<String, dynamic> body) {
    final pending = _pendingRequest;
    if (pending != null && jsonEncode(pending['body']) != jsonEncode(body)) {
      throw const RoomSessionException(
        'pending_message',
        'Retry the existing message before sending changed content.',
      );
    }
    _pendingRequest = <String, dynamic>{'kind': kind, 'body': body};
    _persist();
  }

  void _completePending(int acknowledgedSequence) {
    _nextClientSequence = max(_nextClientSequence, acknowledgedSequence + 1);
    _pendingRequest = null;
    _persist();
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool authenticated = true,
    required Set<int> acceptedStatuses,
  }) async {
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (authenticated)
        'authorization': 'Bearer ${_requireCredentials().token}',
    };
    late http.Response response;
    final uri = config.http(path);
    _recordTransport(
      direction: RoomTransportDirection.frontendToBackend,
      transport: 'http',
      label: '$method $path',
      payload: <String, dynamic>{'method': method, 'path': path, 'body': ?body},
    );
    try {
      response = switch (method) {
        'POST' =>
          await _http
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 20)),
        'DELETE' =>
          await _http
              .delete(uri, headers: headers)
              .timeout(const Duration(seconds: 20)),
        _ =>
          await _http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 20)),
      };
    } on TimeoutException {
      _recordTransport(
        direction: RoomTransportDirection.backendToFrontend,
        transport: 'http',
        label: '$method $path · timeout',
        payload: const <String, dynamic>{'error': 'timeout'},
      );
      throw const RoomSessionException(
        'timeout',
        'The room did not respond in time.',
        retryable: true,
      );
    } on Object {
      _recordTransport(
        direction: RoomTransportDirection.backendToFrontend,
        transport: 'http',
        label: '$method $path · unreachable',
        payload: const <String, dynamic>{'error': 'unreachable'},
      );
      throw const RoomSessionException(
        'unreachable',
        'The room could not be reached.',
        retryable: true,
      );
    }
    _recordTransport(
      direction: RoomTransportDirection.backendToFrontend,
      transport: 'http',
      label: '$method $path · HTTP ${response.statusCode}',
      payload: <String, dynamic>{
        'status': response.statusCode,
        'body': _responseBodyForTrace(response.body),
      },
    );
    if (!acceptedStatuses.contains(response.statusCode)) {
      var code = 'http_${response.statusCode}';
      try {
        code = decodeRoomObject(response.body)['error'] as String? ?? code;
      } on Object {
        // Status code remains a content-free fallback.
      }
      if (authenticated && response.statusCode == 410) {
        await _finishLocally('This room has ended or expired.');
      }
      throw RoomSessionException(
        code,
        _friendlyHttpError(response.statusCode, code),
        retryable: response.statusCode == 429 || response.statusCode >= 500,
      );
    }
    if (response.statusCode == 204) return const <String, dynamic>{};
    try {
      return decodeRoomObject(response.body);
    } on Object {
      throw const RoomSessionException(
        'invalid_response',
        'The room returned invalid data.',
      );
    }
  }

  RoomCredentials _requireCredentials() {
    final current = _credentials;
    if (current == null) {
      throw const RoomSessionException(
        'no_room',
        'Create or join a room first.',
      );
    }
    return current;
  }

  void _recordTransport({
    required RoomTransportDirection direction,
    required String transport,
    required String label,
    required Object? payload,
  }) {
    const maximumEntries = 24;
    if (_transportTrace.length >= maximumEntries) {
      _transportTrace.removeAt(0);
    }
    _transportTrace.add(
      RoomTransportTrace(
        occurredAt: DateTime.now(),
        direction: direction,
        transport: transport,
        label: label,
        payload: _redactTransportPayload(payload),
      ),
    );
  }

  void _persist() {
    final current = _credentials;
    if (current == null) return;
    _storage.write(
      jsonEncode(<String, dynamic>{
        'credentials': current.toJson(),
        'next_client_sequence': _nextClientSequence,
        if (_pendingRequest != null) 'pending_request': _pendingRequest,
      }),
    );
  }

  Future<void> _closeSocket() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.sink.close();
  }

  Future<void> _finishLocally(String message) async {
    _status = RoomConnectionStatus.ended;
    _cancelTerminalRecovery();
    await _closeSocket();
    _credentials = null;
    _messages.clear();
    _participants.clear();
    _activity.clear();
    _spokenTerminalMessages.clear();
    _pendingRequest = null;
    _roomVersion = -1;
    _contextVersion = 0;
    _nextClientSequence = 0;
    _storage.clear();
    _error = message;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTerminalRecovery();
    unawaited(_closeSocket());
    if (_ownsHttp) _http.close();
    super.dispose();
  }
}

/// A trace entry rendered in the optional in-app transport inspector. Entries
/// are deliberately short-lived: [RoomSessionController] keeps only the most
/// recent 24 in memory and does not persist them with room credentials.
final class RoomTransportTrace {
  const RoomTransportTrace({
    required this.occurredAt,
    required this.direction,
    required this.transport,
    required this.label,
    required this.payload,
  });

  final DateTime occurredAt;
  final RoomTransportDirection direction;
  final String transport;
  final String label;
  final Object? payload;

  String get formattedPayload =>
      const JsonEncoder.withIndent('  ').convert(payload);
}

enum RoomTransportDirection { frontendToBackend, backendToFrontend }

Object? _responseBodyForTrace(String responseBody) {
  if (responseBody.isEmpty) return null;
  try {
    return jsonDecode(responseBody);
  } on FormatException {
    return responseBody;
  }
}

Object? _redactTransportPayload(Object? value, {String? fieldName}) {
  final normalizedName = fieldName?.toLowerCase() ?? '';
  if (normalizedName.contains('token') ||
      normalizedName.contains('authorization') ||
      normalizedName.contains('capability') ||
      normalizedName.contains('secret')) {
    return '[redacted]';
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      Map<String, Object?>.fromEntries(
        value.entries.map((entry) {
          final key = entry.key.toString();
          return MapEntry<String, Object?>(
            key,
            _redactTransportPayload(entry.value, fieldName: key),
          );
        }),
      ),
    );
  }
  if (value is Iterable) {
    return List<Object?>.unmodifiable(
      value.map((item) => _redactTransportPayload(item)),
    );
  }
  if (value is String && value.length > 4000) {
    return '${value.substring(0, 4000)}… [truncated]';
  }
  return value;
}

final class RoomSessionException implements Exception {
  const RoomSessionException(this.code, this.message, {this.retryable = false});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'RoomSessionException($code): $message';
}

String _normalizeCode(String value) {
  final result = value.trim().toUpperCase();
  if (!RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$').hasMatch(result)) {
    throw const RoomSessionException(
      'invalid_code',
      'Enter the eight-character room code.',
    );
  }
  return result;
}

String _friendlyHttpError(int status, String code) => switch (status) {
  401 => 'This participant connection is no longer authorized.',
  403 => 'This frontend origin is not allowed by the backend.',
  409 =>
    code == 'sequence_conflict'
        ? 'The message sequence conflicted. Reconnect before retrying.'
        : 'The room is waiting for its second participant.',
  410 => 'This room has ended or expired.',
  413 => 'The message is too large.',
  422 => 'The backend rejected this message format.',
  429 => 'The room is busy. Retry shortly.',
  _ => 'The room request failed (HTTP $status).',
};

String _messageFor(Object failure) => switch (failure) {
  RoomSessionException exception => exception.message,
  _ => 'The room connection failed.',
};

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
