import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/contracts/gloss_lattice_session.dart';

const sessionId = '3dd5e15d-991a-4c27-9a11-af4a1a3bb2e8';
const streamToken = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH';
const latticePath = '/v1/sessions/$sessionId/lattices';

GlossLatticeProducer sessionProducer() => GlossLatticeProducer(
  classifierId: 'simplynext_temporal',
  classifierVersion: 'asl_demo_v3',
  calibrationVersion: 'temperature_v2',
  vocabularyVersion: 'demo_v1',
);

GlossLatticeSessionCreateRequest sessionRequest() =>
    GlossLatticeSessionCreateRequest(
      language: GlossLatticeLanguage.asl,
      client: GlossLatticeClientDescriptor(
        platform: GlossLatticeClientPlatform.android,
        appVersion: '1.0.0',
        deviceModel: 'demo-phone',
      ),
      detector: GlossLatticeDetectorDescriptor(
        name: 'mediapipe-holistic',
        version: '0.10.22',
        delegate: GlossLatticeDetectorDelegate.gpu,
      ),
      producer: sessionProducer(),
    );

/// Response shape currently produced by `integration/gloss-lattice-only`.
Map<String, dynamic> latticeOnlySessionResponseJson() => <String, dynamic>{
  'session_id': sessionId,
  'stream_token': streamToken,
  'token_type': 'Bearer',
  'stream_kind': 'gloss_lattice',
  'websocket_path': latticePath,
  'created_at': '2026-09-07T10:00:00Z',
  'expires_at': '2026-09-07T10:15:00Z',
  'lattice_schema_version': '1.0',
  'max_lattice_message_bytes': 32768,
  'max_lattice_slots': 64,
  'max_candidates_per_slot': 5,
};

/// Original `front_back_contract` compatibility response shape.
Map<String, dynamic> frozenSessionResponseJson() => <String, dynamic>{
  ...latticeOnlySessionResponseJson(),
  'lattice_websocket_path': latticePath,
  'layout': <String, dynamic>{
    'version': '1.0',
    'point_format': 'x,y,z,confidence',
    'hand': <String>['wrist', 'thumb_cmc'],
    'pose': <String>['nose', 'left_shoulder', 'right_shoulder'],
    'face': <String>['nose_tip', 'chin'],
  },
  'max_batch_frames': 8,
  'target_fps': 30,
};
