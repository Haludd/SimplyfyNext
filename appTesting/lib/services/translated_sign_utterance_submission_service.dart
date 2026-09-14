import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contracts/translated_sign_utterance.dart';

/// HTTP transport for the v1 room ingress. It sends a completed utterance and
/// returns only the immediate admission acknowledgement; the assembled
/// sentence or repair must arrive over the authenticated room event channel.
final class TranslatedSignUtteranceSubmissionService {
  TranslatedSignUtteranceSubmissionService({
    this.endpoint,
    String? participantCapability,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _participantCapability = participantCapability?.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null {
    final target = endpoint;
    if (target != null &&
        (!target.isAbsolute ||
            target.host.isEmpty ||
            (target.scheme != 'http' && target.scheme != 'https'))) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must be an absolute http or https URL',
      );
    }
    if (target != null &&
        target.scheme == 'http' &&
        !_isLoopbackHost(target.host)) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must use HTTPS outside local loopback development',
      );
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
  }

  /// Configure the exact authenticated room endpoint at build time, for
  /// example:
  ///
  /// --dart-define=SIGNBRIDGE_SIGN_UTTERANCE_URL=https://…/v1/rooms/ABC/sign-utterances
  /// --dart-define=SIGNBRIDGE_PARTICIPANT_CAPABILITY=…
  ///
  /// The capability is intentionally not represented in the payload or UI.
  factory TranslatedSignUtteranceSubmissionService.fromEnvironment({
    http.Client? client,
  }) {
    const endpointText = String.fromEnvironment(
      'SIGNBRIDGE_SIGN_UTTERANCE_URL',
    );
    const capability = String.fromEnvironment(
      'SIGNBRIDGE_PARTICIPANT_CAPABILITY',
    );
    final trimmedEndpoint = endpointText.trim();
    return TranslatedSignUtteranceSubmissionService(
      endpoint: trimmedEndpoint.isEmpty ? null : Uri.parse(trimmedEndpoint),
      participantCapability: capability,
      client: client,
    );
  }

  final Uri? endpoint;
  final String? _participantCapability;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  bool _closed = false;

  bool get isConfigured =>
      endpoint != null && (_participantCapability?.isNotEmpty ?? false);

  String? get configurationMessage {
    if (endpoint == null) {
      return 'No sign-utterance room endpoint is configured.';
    }
    if (_participantCapability?.isEmpty ?? true) {
      return 'No participant capability is configured for the room.';
    }
    return null;
  }

  Future<TranslatedSignUtteranceAcknowledgement> submit(
    TranslatedSignUtterance utterance,
  ) async {
    if (_closed) {
      throw StateError('TranslatedSignUtteranceSubmissionService is closed.');
    }
    final target = endpoint;
    final capability = _participantCapability;
    if (target == null || capability == null || capability.isEmpty) {
      throw TranslatedSignUtteranceSubmissionException(
        code: 'not_configured',
        message: configurationMessage ?? 'Room submission is not configured.',
      );
    }

    final body = utterance.toWireJson();
    if (utf8.encode(body).length >
        TranslatedSignUtteranceContract.maxMessageBytes) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'payload_too_large',
        message: 'The final utterance exceeds the 16 KiB room limit.',
      );
    }

    late http.Response response;
    try {
      response = await _client
          .post(
            target,
            headers: <String, String>{
              'accept': 'application/json',
              'content-type': 'application/json',
              'authorization': 'Bearer $capability',
            },
            body: body,
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'timeout',
        message: 'The room did not acknowledge the utterance in time.',
        retryable: true,
      );
    } on Object {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'unreachable',
        message: 'The room could not be reached. The same utterance can retry.',
        retryable: true,
      );
    }

    if (response.statusCode != 202) {
      throw _responseException(response.statusCode);
    }
    if (response.bodyBytes.length > 64 * 1024) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room acknowledgement is unexpectedly large.',
      );
    }
    if (response.bodyBytes.isEmpty) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room did not return an acknowledgement.',
      );
    }

    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException('not an object');
      payload = Map<String, dynamic>.from(decoded);
    } on Object {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room returned an invalid acknowledgement.',
      );
    }
    return TranslatedSignUtteranceAcknowledgement.fromJson(
      payload,
      expectedMessageId: utterance.messageId,
      expectedClientSequence: utterance.clientSequence,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  TranslatedSignUtteranceSubmissionException _responseException(int status) =>
      switch (status) {
        401 => const TranslatedSignUtteranceSubmissionException(
          code: 'unauthorized',
          message: 'The room did not accept this participant capability.',
        ),
        409 => const TranslatedSignUtteranceSubmissionException(
          code: 'sequence_conflict',
          message: 'This utterance conflicts with the room sequence.',
        ),
        410 => const TranslatedSignUtteranceSubmissionException(
          code: 'room_unavailable',
          message: 'This room is no longer available.',
        ),
        413 => const TranslatedSignUtteranceSubmissionException(
          code: 'payload_too_large',
          message: 'The final utterance exceeds the room size limit.',
        ),
        422 => const TranslatedSignUtteranceSubmissionException(
          code: 'invalid_utterance',
          message: 'The room rejected this utterance format.',
        ),
        429 => const TranslatedSignUtteranceSubmissionException(
          code: 'rate_limited',
          message: 'The room is busy. Retry this same utterance shortly.',
          retryable: true,
        ),
        _ => TranslatedSignUtteranceSubmissionException(
          code: 'http_$status',
          message: 'The room rejected the utterance (HTTP $status).',
          retryable: status >= 500,
        ),
      };
}

/// Admission only. A 202 response is not an assembled sentence.
final class TranslatedSignUtteranceAcknowledgement {
  TranslatedSignUtteranceAcknowledgement({
    required this.messageId,
    required this.clientSequence,
    required this.serverSequence,
    required this.disposition,
  });

  factory TranslatedSignUtteranceAcknowledgement.fromJson(
    Map<String, dynamic> json, {
    required String expectedMessageId,
    required int expectedClientSequence,
  }) {
    const keys = <String>{
      'event_schema_version',
      'type',
      'message_id',
      'client_sequence',
      'server_sequence',
      'disposition',
    };
    if (json.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(json.keys.toSet()).isNotEmpty) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room acknowledgement has an unsupported shape.',
      );
    }
    if (json['event_schema_version'] != '1.0' ||
        json['type'] != 'utterance_ack') {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room acknowledgement has an unsupported type.',
      );
    }
    final messageId = json['message_id'];
    final clientSequence = json['client_sequence'];
    final serverSequence = json['server_sequence'];
    final disposition = json['disposition'];
    if (messageId is! String ||
        messageId != expectedMessageId ||
        clientSequence is! int ||
        clientSequence != expectedClientSequence ||
        serverSequence is! int ||
        serverSequence < 0 ||
        disposition is! String ||
        (disposition != 'accepted' && disposition != 'cached')) {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room acknowledgement does not match this utterance.',
      );
    }
    return TranslatedSignUtteranceAcknowledgement(
      messageId: messageId,
      clientSequence: clientSequence,
      serverSequence: serverSequence,
      disposition: disposition,
    );
  }

  final String messageId;
  final int clientSequence;
  final int serverSequence;
  final String disposition;

  bool get wasCached => disposition == 'cached';
}

final class TranslatedSignUtteranceSubmissionException implements Exception {
  const TranslatedSignUtteranceSubmissionException({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() =>
      'TranslatedSignUtteranceSubmissionException($code): $message';
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized == '::1' ||
      normalized.startsWith('127.');
}
