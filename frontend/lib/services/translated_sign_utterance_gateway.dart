import '../contracts/translated_sign_utterance.dart';

abstract interface class TranslatedSignUtteranceGateway {
  bool get isConfigured;
  String? get configurationMessage;
  int get nextClientSequence;

  Future<TranslatedSignUtteranceAcknowledgement> submit(
    TranslatedSignUtterance utterance,
  );
}

final class TranslatedSignUtteranceAcknowledgement {
  const TranslatedSignUtteranceAcknowledgement({
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
        keys.difference(json.keys.toSet()).isNotEmpty ||
        json['event_schema_version'] != '1.0' ||
        json['type'] != 'utterance_ack') {
      throw const TranslatedSignUtteranceSubmissionException(
        code: 'invalid_response',
        message: 'The room acknowledgement has an unsupported shape.',
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
