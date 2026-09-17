import 'dart:convert';

import 'package:apptesting/contracts/translated_sign_utterance.dart';
import 'package:apptesting/models/asl_recognition_models.dart';
import 'package:apptesting/services/asl_label_to_english.dart';
import 'package:apptesting/services/translated_sign_utterance_submission_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _messageId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  final producer = TranslatedSignUtteranceProducer(
    recognizerId: 'signchat_asl_signs_onnx',
    recognizerVersion: 'signchat_asl_signs_onnx',
    translatorId: 'asl_label_to_english',
    translatorVersion: '1.0.0',
    vocabularyVersion: 'popsign_250_en_v1',
    confidenceKind: TranslatedSignUtteranceConfidenceKind.normalizedModelScore,
  );

  test('accepts personal and combined local recognition profiles', () {
    for (final values in <(String, String, String)>[
      (
        'personal_landmark_templates',
        'personal_landmark_templates_v1',
        'personal_signs_local_v1',
      ),
      (
        'signbridge_local_recognizers',
        'signbridge_local_recognizers_v1',
        'popsign_250_plus_personal_v1',
      ),
    ]) {
      expect(
        () => TranslatedSignUtteranceProducer(
          recognizerId: values.$1,
          recognizerVersion: values.$2,
          translatorId: 'asl_label_to_english',
          translatorVersion: '1.0.0',
          vocabularyVersion: values.$3,
          confidenceKind:
              TranslatedSignUtteranceConfidenceKind.normalizedModelScore,
        ),
        returnsNormally,
      );
    }
  });

  test('rejects mismatched local recognition profile fields', () {
    expect(
      () => TranslatedSignUtteranceProducer(
        recognizerId: 'personal_landmark_templates',
        recognizerVersion: 'signchat_asl_signs_onnx',
        translatorId: 'asl_label_to_english',
        translatorVersion: '1.0.0',
        vocabularyVersion: 'personal_signs_local_v1',
        confidenceKind:
            TranslatedSignUtteranceConfidenceKind.normalizedModelScore,
      ),
      throwsA(isA<TranslatedSignUtteranceValidationException>()),
    );
  });

  test('serializes the exact final utterance shape without capture data', () {
    final utterance = TranslatedSignUtterance(
      messageId: _messageId,
      clientSequence: 0,
      completionReason: TranslatedSignUtteranceCompletionReason.userCommit,
      producer: producer,
      words: <TranslatedSignWordToken>[
        TranslatedSignWordToken(
          index: 0,
          tokenId: 'word-0',
          word: 'THANK',
          confidence: .96,
          alternatives: <TranslatedSignWordAlternative>[
            TranslatedSignWordAlternative(
              rank: 2,
              word: 'THINK',
              confidence: .02,
            ),
          ],
        ),
        TranslatedSignWordToken(
          index: 1,
          tokenId: 'word-1',
          word: 'YOU',
          confidence: .96,
        ),
      ],
    );

    final wire = jsonDecode(utterance.toWireJson()) as Map<String, dynamic>;
    expect(wire['type'], 'translated_sign_utterance');
    expect(wire['schema_version'], '1.0');
    expect(wire['is_final'], isTrue);
    expect(wire['completion_reason'], 'user_commit');
    expect(wire['words'], hasLength(2));
    expect(wire, isNot(contains('landmarks')));
    expect(wire, isNot(contains('frames')));
    expect(wire, isNot(contains('glosses')));
  });

  test('rejects non-contiguous alternative ranks before transport', () {
    expect(
      () => TranslatedSignWordToken(
        index: 0,
        tokenId: 'word-0',
        word: 'HELLO',
        confidence: .9,
        alternatives: <TranslatedSignWordAlternative>[
          TranslatedSignWordAlternative(rank: 3, word: 'HI', confidence: .1),
        ],
      ),
      throwsA(isA<TranslatedSignUtteranceValidationException>()),
    );
  });

  test('translates compact model labels into lexical English words', () {
    final translation = const AslLabelToEnglish().translate(
      const AslRecognitionResult(
        status: 'recognized',
        word: 'thankyou',
        confidence: .96,
        modelVersion: 'signchat_asl_signs_onnx',
        frameCount: 16,
      ),
    );

    expect(translation.words, <String>['THANK', 'YOU']);
    expect(translation.alternatives, isEmpty);
  });

  test(
    'posts one authenticated final utterance and parses only its ack',
    () async {
      http.Request? request;
      final service = TranslatedSignUtteranceSubmissionService(
        endpoint: Uri.parse('http://localhost/v1/rooms/ROOM/sign-utterances'),
        participantCapability: 'capability-not-in-payload',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'type': 'utterance_ack',
              'message_id': _messageId,
              'client_sequence': 0,
              'server_sequence': 1,
              'disposition': 'accepted',
            }),
            202,
          );
        }),
      );
      addTearDown(service.close);
      final utterance = TranslatedSignUtterance(
        messageId: _messageId,
        clientSequence: 0,
        completionReason: TranslatedSignUtteranceCompletionReason.userCommit,
        producer: producer,
        words: <TranslatedSignWordToken>[
          TranslatedSignWordToken(
            index: 0,
            tokenId: 'word-0',
            word: 'HELLO',
            confidence: .9,
          ),
        ],
      );

      final acknowledgement = await service.submit(utterance);

      expect(acknowledgement.serverSequence, 1);
      expect(
        request?.headers['authorization'],
        'Bearer capability-not-in-payload',
      );
      final sent = jsonDecode(request!.body) as Map<String, dynamic>;
      expect(sent['words'], hasLength(1));
      expect(sent, isNot(contains('participant_id')));
      expect(sent, isNot(contains('room_code')));
      expect(sent, isNot(contains('frames')));
    },
  );
}
