import 'dart:convert';

import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/contracts/gloss_lattice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/gloss_lattice_session_fixtures.dart';

void main() {
  group('GlossLattice session request', () {
    test('serializes the exact gloss_lattice negotiation names', () {
      expect(sessionRequest().toJson(), <String, dynamic>{
        'language': 'asl',
        'schema_version': '1.0',
        'stream_kind': 'gloss_lattice',
        'client': <String, dynamic>{
          'platform': 'android',
          'app_version': '1.0.0',
          'device_model': 'demo-phone',
        },
        'detector': <String, dynamic>{
          'name': 'mediapipe-holistic',
          'version': '0.10.22',
          'delegate': 'gpu',
        },
        'producer': <String, dynamic>{
          'classifier_id': 'simplynext_temporal',
          'classifier_version': 'asl_demo_v3',
          'confidence_kind': 'calibrated_probability',
          'calibration_version': 'temperature_v2',
          'vocabulary_version': 'demo_v1',
        },
      });
    });

    test('emits compact valid JSON', () {
      final encoded = sessionRequest().toWireJson();
      expect(encoded, isNot(contains('\n')));
      expect(jsonDecode(encoded), sessionRequest().toJson());
    });

    test('validates client string boundaries exactly', () {
      expect(
        () => GlossLatticeClientDescriptor(
          platform: GlossLatticeClientPlatform.android,
          appVersion: '',
        ),
        throwsA(isA<GlossLatticeValidationException>()),
      );
      expect(
        () => GlossLatticeClientDescriptor(
          platform: GlossLatticeClientPlatform.android,
          appVersion: _repeat('v', 64),
          deviceModel: _repeat('d', 128),
        ),
        returnsNormally,
      );
      expect(
        () => GlossLatticeClientDescriptor(
          platform: GlossLatticeClientPlatform.android,
          appVersion: _repeat('v', 65),
        ),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });

    test('validates detector string boundaries exactly', () {
      expect(
        () => GlossLatticeDetectorDescriptor(name: '', version: '1'),
        throwsA(isA<GlossLatticeValidationException>()),
      );
      expect(
        () => GlossLatticeDetectorDescriptor(
          name: _repeat('n', 128),
          version: _repeat('v', 64),
        ),
        returnsNormally,
      );
      expect(
        () => GlossLatticeDetectorDescriptor(
          name: _repeat('n', 129),
          version: '1',
        ),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });
  });

  group('GlossLattice session response', () {
    test('parses the lattice-only backend response exactly', () {
      final response = GlossLatticeSessionCreateResponse.fromJson(
        latticeOnlySessionResponseJson(),
      );

      expect(response.sessionId, sessionId);
      expect(response.streamToken, streamToken);
      expect(response.tokenType, 'Bearer');
      expect(response.streamKind, 'gloss_lattice');
      expect(response.websocketPath, latticePath);
      expect(response.latticeWebsocketPath, isNull);
      expect(response.createdAt, DateTime.utc(2026, 9, 7, 10));
      expect(response.expiresAt, DateTime.utc(2026, 9, 7, 10, 15));
      expect(response.layout, isNull);
      expect(response.maxBatchFrames, isNull);
      expect(response.targetFps, isNull);
      expect(response.latticeSchemaVersion, '1.0');
      expect(response.maxLatticeMessageBytes, 32768);
      expect(response.maxLatticeSlots, 64);
      expect(response.maxCandidatesPerSlot, 5);
    });

    test('parses the frozen compatibility response exactly', () {
      final response = GlossLatticeSessionCreateResponse.fromJson(
        frozenSessionResponseJson(),
      );

      expect(response.websocketPath, latticePath);
      expect(response.latticeWebsocketPath, latticePath);
      expect(response.layout?['version'], '1.0');
      expect(response.maxBatchFrames, 8);
      expect(response.targetFps, 30);
      expect(
        () => response.layout!['version'] = 'changed',
        throwsUnsupportedError,
      );
    });

    test('accepts transitional null landmark limits without using them', () {
      final json = latticeOnlySessionResponseJson()
        ..['layout'] = null
        ..['max_batch_frames'] = null
        ..['target_fps'] = null;

      final response = GlossLatticeSessionCreateResponse.fromJson(json);

      expect(response.layout, isNull);
      expect(response.maxBatchFrames, isNull);
      expect(response.targetFps, isNull);
    });

    test('parses an aware offset datetime and converts it to UTC', () {
      final json = latticeOnlySessionResponseJson()
        ..['created_at'] = '2026-09-07T18:00:00+08:00'
        ..['expires_at'] = '2026-09-07T18:15:00+08:00';
      final response = GlossLatticeSessionCreateResponse.fromJson(json);

      expect(response.createdAt, DateTime.utc(2026, 9, 7, 10));
      expect(response.expiresAt, DateTime.utc(2026, 9, 7, 10, 15));
    });

    test('parses the response from UTF-8 JSON text', () {
      final response = GlossLatticeSessionCreateResponse.fromWireJson(
        jsonEncode(latticeOnlySessionResponseJson()),
      );
      expect(response.sessionId, sessionId);
    });

    test('rejects malformed JSON and non-object JSON', () {
      expect(
        () => GlossLatticeSessionCreateResponse.fromWireJson('{'),
        throwsA(isA<GlossLatticeValidationException>()),
      );
      expect(
        () => GlossLatticeSessionCreateResponse.fromWireJson('[]'),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });

    test('rejects every missing common property', () {
      for (final field in latticeOnlySessionResponseJson().keys) {
        final json = latticeOnlySessionResponseJson()..remove(field);
        expect(
          () => GlossLatticeSessionCreateResponse.fromJson(json),
          throwsA(isA<GlossLatticeValidationException>()),
          reason: 'missing $field must fail',
        );
      }
    });

    test('rejects unknown properties', () {
      final json = latticeOnlySessionResponseJson()..['access_token'] = 'bad';
      expect(
        () => GlossLatticeSessionCreateResponse.fromJson(json),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });

    test('rejects invalid identity and negotiation literals', () {
      final invalidValues = <String, Object?>{
        'session_id': 'not-a-uuid',
        'stream_token': 'too-short',
        'token_type': 'Basic',
        'stream_kind': 'landmarks',
        'lattice_schema_version': '2.0',
        'max_lattice_message_bytes': 32767,
        'max_lattice_slots': 65,
        'max_candidates_per_slot': 6,
      };
      for (final entry in invalidValues.entries) {
        final json = latticeOnlySessionResponseJson()
          ..[entry.key] = entry.value;
        expect(
          () => GlossLatticeSessionCreateResponse.fromJson(json),
          throwsA(isA<GlossLatticeValidationException>()),
          reason: '${entry.key}=${entry.value} must fail',
        );
      }
    });

    test('rejects a path for another session or a token query', () {
      for (final path in <String>[
        '/v1/sessions/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/lattices',
        '$latticePath?token=$streamToken',
        'wss://api.example.test$latticePath',
      ]) {
        final json = latticeOnlySessionResponseJson()
          ..['websocket_path'] = path;
        expect(
          () => GlossLatticeSessionCreateResponse.fromJson(json),
          throwsA(isA<GlossLatticeValidationException>()),
          reason: '$path must fail',
        );
      }
    });

    test('rejects mismatched frozen path aliases', () {
      final json = frozenSessionResponseJson()
        ..['lattice_websocket_path'] =
            '/v1/sessions/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/lattices';
      expect(
        () => GlossLatticeSessionCreateResponse.fromJson(json),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });

    test('rejects timezone-free or reversed session lifetimes', () {
      final noTimezone = latticeOnlySessionResponseJson()
        ..['created_at'] = '2026-09-07T10:00:00';
      expect(
        () => GlossLatticeSessionCreateResponse.fromJson(noTimezone),
        throwsA(isA<GlossLatticeValidationException>()),
      );

      final reversed = latticeOnlySessionResponseJson()
        ..['expires_at'] = '2026-09-07T09:59:59Z';
      expect(
        () => GlossLatticeSessionCreateResponse.fromJson(reversed),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });

    test('rejects populated landmark limits in lattice-only shape', () {
      final json = latticeOnlySessionResponseJson()..['target_fps'] = 30;
      expect(
        () => GlossLatticeSessionCreateResponse.fromJson(json),
        throwsA(isA<GlossLatticeValidationException>()),
      );
    });
  });
}

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();
