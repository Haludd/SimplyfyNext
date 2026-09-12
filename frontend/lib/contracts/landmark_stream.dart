import 'dart:convert';

/// Version of the server-side landmark stream contract.
const String landmarkStreamSchemaVersion = '1.0';

/// This client owns only capture. The backend owns normalisation,
/// segmentation, and classification, so the negotiated stream must be the
/// raw-landmark stream rather than the finalized gloss-lattice stream.
const String landmarkStreamKind = 'landmarks';

enum LandmarkStreamClientPlatform {
  android('android'),
  ios('ios'),
  test('test');

  const LandmarkStreamClientPlatform(this.wireValue);

  final String wireValue;
}

enum LandmarkStreamDetectorDelegate {
  cpu('cpu'),
  gpu('gpu'),
  nnapi('nnapi'),
  coreMl('core_ml'),
  unknown('unknown');

  const LandmarkStreamDetectorDelegate(this.wireValue);

  final String wireValue;
}

final class LandmarkStreamClientDescriptor {
  LandmarkStreamClientDescriptor({
    required this.platform,
    required this.appVersion,
    this.deviceModel,
  }) {
    _validateText(appVersion, 'client.app_version', 64);
    if (deviceModel != null) {
      _validateText(deviceModel!, 'client.device_model', 128);
    }
  }

  final LandmarkStreamClientPlatform platform;
  final String appVersion;
  final String? deviceModel;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'platform': platform.wireValue,
    'app_version': appVersion,
    if (deviceModel != null) 'device_model': deviceModel,
  };
}

final class LandmarkStreamDetectorDescriptor {
  LandmarkStreamDetectorDescriptor({
    required this.name,
    required this.version,
    this.delegate = LandmarkStreamDetectorDelegate.unknown,
  }) {
    _validateText(name, 'detector.name', 128);
    _validateText(version, 'detector.version', 64);
  }

  final String name;
  final String version;
  final LandmarkStreamDetectorDelegate delegate;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'version': version,
    'delegate': delegate.wireValue,
  };
}

final class LandmarkStreamSessionCreateRequest {
  const LandmarkStreamSessionCreateRequest({
    required this.language,
    required this.client,
    required this.detector,
  });

  final String language;
  final LandmarkStreamClientDescriptor client;
  final LandmarkStreamDetectorDescriptor detector;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'language': language,
    'schema_version': landmarkStreamSchemaVersion,
    'stream_kind': landmarkStreamKind,
    'client': client.toJson(),
    'detector': detector.toJson(),
  };

  String toWireJson() => jsonEncode(toJson());
}

final class LandmarkStreamSession {
  LandmarkStreamSession({
    required this.sessionId,
    required this.streamToken,
    required this.websocketPath,
    required this.createdAt,
    required this.expiresAt,
    required this.layout,
    required this.maxBatchFrames,
    required this.targetFps,
  }) {
    if (!_isCanonicalUuid(sessionId)) {
      throw const FormatException('session_id must be a canonical UUID');
    }
    _validateText(streamToken, 'stream_token', 256, minimum: 32);
    if (!websocketPath.startsWith('/')) {
      throw const FormatException('websocket_path must be an absolute path');
    }
    if (!expiresAt.isAfter(createdAt)) {
      throw const FormatException('expires_at must be after created_at');
    }
    if (maxBatchFrames < 1 || maxBatchFrames > 32) {
      throw const FormatException('max_batch_frames is outside the contract');
    }
    if (targetFps < 1 || targetFps > 60) {
      throw const FormatException('target_fps is outside the contract');
    }
  }

  final String sessionId;
  final String streamToken;
  final String websocketPath;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Map<String, dynamic> layout;
  final int maxBatchFrames;
  final int targetFps;

  factory LandmarkStreamSession.fromJson(Map<String, dynamic> json) {
    final sessionId = _requiredString(json, 'session_id');
    final tokenType = _requiredString(json, 'token_type');
    if (tokenType != 'Bearer') {
      throw const FormatException('token_type must be Bearer');
    }
    final rawLayout = json['layout'];
    if (rawLayout is! Map) {
      throw const FormatException('layout must be an object');
    }
    final createdAt = _requiredDateTime(json, 'created_at');
    final expiresAt = _requiredDateTime(json, 'expires_at');
    final maxBatchFrames = _requiredInt(json, 'max_batch_frames');
    final targetFps = _requiredInt(json, 'target_fps');
    return LandmarkStreamSession(
      sessionId: sessionId,
      streamToken: _requiredString(json, 'stream_token'),
      websocketPath: _requiredString(json, 'websocket_path'),
      createdAt: createdAt,
      expiresAt: expiresAt,
      layout: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(rawLayout),
      ),
      maxBatchFrames: maxBatchFrames,
      targetFps: targetFps,
    );
  }
}

final class LandmarkCameraGeometry {
  const LandmarkCameraGeometry({
    required this.sourceWidth,
    required this.sourceHeight,
    this.rotationDegrees = 0,
    required this.mirroredInput,
  });

  final int sourceWidth;
  final int sourceHeight;
  final int rotationDegrees;
  final bool mirroredInput;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source_width': sourceWidth,
    'source_height': sourceHeight,
    'rotation_degrees': rotationDegrees,
    'mirrored_input': mirroredInput,
    'coordinates_canonical': true,
  };
}

final class LandmarkBatch {
  LandmarkBatch({
    required this.sessionId,
    required this.batchSeq,
    required this.camera,
    required List<Map<String, dynamic>> frames,
    this.droppedBefore = 0,
  }) : frames = List<Map<String, dynamic>>.unmodifiable(
         frames.map((frame) => Map<String, dynamic>.unmodifiable(frame)),
       ) {
    if (!_isCanonicalUuid(sessionId)) {
      throw const FormatException('session_id must be a canonical UUID');
    }
    if (batchSeq < 0) throw const FormatException('batch_seq must be >= 0');
    if (this.frames.isEmpty || this.frames.length > 32) {
      throw const FormatException('frames must contain 1 through 32 items');
    }
    if (droppedBefore < 0) {
      throw const FormatException('dropped_before must be >= 0');
    }
  }

  final String sessionId;
  final int batchSeq;
  final LandmarkCameraGeometry camera;
  final List<Map<String, dynamic>> frames;
  final int droppedBefore;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'landmark_batch',
    'schema_version': landmarkStreamSchemaVersion,
    'session_id': sessionId,
    'batch_seq': batchSeq,
    'camera': camera.toJson(),
    'frames': frames,
    'dropped_before': droppedBefore,
  };

  String toWireJson() => jsonEncode(toJson());
}

Map<String, dynamic> landmarkStreamControl({
  required String sessionId,
  required int controlSeq,
  required String action,
  int? clientMs,
}) => <String, dynamic>{
  'type': 'control',
  'session_id': sessionId,
  'control_seq': controlSeq,
  'action': action,
  'client_ms': ?clientMs,
};

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('$key must be an aware UTC datetime');
  }
  return parsed;
}

bool _isCanonicalUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
).hasMatch(value);

void _validateText(
  String value,
  String name,
  int maximum, {
  int minimum = 1,
}) {
  if (value.trim().length < minimum || value.length > maximum) {
    throw ArgumentError.value(value, name, 'has an invalid length');
  }
}
