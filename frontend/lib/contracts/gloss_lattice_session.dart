import 'dart:convert';

import 'gloss_lattice.dart';

/// Platforms accepted by the current backend session contract.
///
/// The backend contract does not currently define a `web` value. Browser
/// support also needs a ticket/cookie authentication design before a browser
/// can open the protected WebSocket.
enum GlossLatticeClientPlatform {
  android('android'),
  ios('ios'),
  test('test');

  const GlossLatticeClientPlatform(this.wireValue);

  final String wireValue;
}

enum GlossLatticeDetectorDelegate {
  cpu('cpu'),
  gpu('gpu'),
  nnapi('nnapi'),
  coreMl('core_ml'),
  unknown('unknown');

  const GlossLatticeDetectorDelegate(this.wireValue);

  final String wireValue;
}

/// Identifies the frontend application during session negotiation.
final class GlossLatticeClientDescriptor {
  GlossLatticeClientDescriptor({
    required this.platform,
    required this.appVersion,
    this.deviceModel,
  }) {
    _validateLength(appVersion, 'client.app_version', minimum: 1, maximum: 64);
    final model = deviceModel;
    if (model != null) {
      _validateLength(model, 'client.device_model', minimum: 1, maximum: 128);
    }
  }

  final GlossLatticeClientPlatform platform;
  final String appVersion;
  final String? deviceModel;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'platform': platform.wireValue,
    'app_version': appVersion,
    'device_model': deviceModel,
  };
}

/// Identifies the frontend landmark detector used before classification.
final class GlossLatticeDetectorDescriptor {
  GlossLatticeDetectorDescriptor({
    required this.name,
    required this.version,
    this.delegate = GlossLatticeDetectorDelegate.unknown,
  }) {
    _validateLength(name, 'detector.name', minimum: 1, maximum: 128);
    _validateLength(version, 'detector.version', minimum: 1, maximum: 64);
  }

  final String name;
  final String version;
  final GlossLatticeDetectorDelegate delegate;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'version': version,
    'delegate': delegate.wireValue,
  };
}

/// Exact request body for `POST /v1/sessions` in `gloss_lattice` mode.
final class GlossLatticeSessionCreateRequest {
  const GlossLatticeSessionCreateRequest({
    required this.language,
    required this.client,
    required this.detector,
    required this.producer,
  });

  static const String streamKind = 'gloss_lattice';

  final GlossLatticeLanguage language;
  final GlossLatticeClientDescriptor client;
  final GlossLatticeDetectorDescriptor detector;
  final GlossLatticeProducer producer;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'language': language.wireValue,
    'schema_version': GlossLatticeContract.schemaVersion,
    'stream_kind': streamKind,
    'client': client.toJson(),
    'detector': detector.toJson(),
    'producer': producer.toJson(),
  };

  String toWireJson() => jsonEncode(toJson());
}

/// Validated response returned when a lattice session is created.
///
/// Two already-published backend snapshots exist. The original frozen
/// transport response includes `lattice_websocket_path` and populated legacy
/// landmark limits. The newer lattice-only implementation omits that alias and
/// the landmark-only fields. A transitional null-valued variant is also
/// accepted. Every form enforces the same frozen lattice limits.
final class GlossLatticeSessionCreateResponse {
  GlossLatticeSessionCreateResponse._({
    required this.sessionId,
    required this.streamToken,
    required this.websocketPath,
    required this.createdAt,
    required this.expiresAt,
    required this.latticeWebsocketPath,
    required this.layout,
    required this.maxBatchFrames,
    required this.targetFps,
  });

  static const Set<String> _latticeKeys = <String>{
    'session_id',
    'stream_token',
    'token_type',
    'stream_kind',
    'websocket_path',
    'created_at',
    'expires_at',
    'lattice_schema_version',
    'max_lattice_message_bytes',
    'max_lattice_slots',
    'max_candidates_per_slot',
  };

  static const Set<String> _nullableCompatibilityKeys = <String>{
    ..._latticeKeys,
    'layout',
    'max_batch_frames',
    'target_fps',
  };

  static const Set<String> _frozenKeys = <String>{
    ..._nullableCompatibilityKeys,
    'lattice_websocket_path',
  };

  final String sessionId;
  final String streamToken;
  final String websocketPath;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// Compatibility alias present in the original frozen transport response.
  final String? latticeWebsocketPath;

  /// Legacy landmark-mode response fields. They are never used to build or
  /// send a GlossLattice, but are retained so parsing remains auditable.
  final Map<String, dynamic>? layout;
  final int? maxBatchFrames;
  final int? targetFps;

  String get tokenType => 'Bearer';
  String get streamKind => GlossLatticeSessionCreateRequest.streamKind;
  String get latticeSchemaVersion => GlossLatticeContract.schemaVersion;
  int get maxLatticeMessageBytes => GlossLatticeContract.maxMessageBytes;
  int get maxLatticeSlots => GlossLatticeContract.maxSlots;
  int get maxCandidatesPerSlot => GlossLatticeContract.maxCandidatesPerSlot;

  factory GlossLatticeSessionCreateResponse.fromWireJson(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw GlossLatticeValidationException(
        'session response must be valid JSON: ${error.message}',
      );
    }
    if (decoded is! Map || decoded.keys.any((Object? key) => key is! String)) {
      throw const GlossLatticeValidationException(
        'session response must be a JSON object',
      );
    }
    return GlossLatticeSessionCreateResponse.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  factory GlossLatticeSessionCreateResponse.fromJson(
    Map<String, dynamic> json,
  ) {
    final keys = json.keys.toSet();
    final isFrozenShape = _sameKeys(keys, _frozenKeys);
    final isLatticeOnlyShape = _sameKeys(keys, _latticeKeys);
    final isNullableCompatibilityShape = _sameKeys(
      keys,
      _nullableCompatibilityKeys,
    );
    if (!isFrozenShape &&
        !isLatticeOnlyShape &&
        !isNullableCompatibilityShape) {
      final expected = <String>{
        ..._latticeKeys,
        '[layout]',
        '[max_batch_frames]',
        '[target_fps]',
        '[lattice_websocket_path]',
      };
      throw GlossLatticeValidationException(
        'session response has an unexpected property set; expected $expected, '
        'received $keys',
      );
    }

    final sessionId = _expectString(json['session_id'], 'session_id');
    if (!GlossLatticeContract.isValidUuid(sessionId)) {
      throw const GlossLatticeValidationException(
        'session_id must be a canonical UUID string',
      );
    }

    final streamToken = _expectString(json['stream_token'], 'stream_token');
    _validateLength(streamToken, 'stream_token', minimum: 32, maximum: 256);
    _expectLiteral(json['token_type'], 'token_type', 'Bearer');
    _expectLiteral(
      json['stream_kind'],
      'stream_kind',
      GlossLatticeSessionCreateRequest.streamKind,
    );

    final websocketPath = _expectString(
      json['websocket_path'],
      'websocket_path',
    );
    _validateWebsocketPath(websocketPath, sessionId, 'websocket_path');

    String? latticeWebsocketPath;
    if (isFrozenShape) {
      final rawPath = json['lattice_websocket_path'];
      if (rawPath is! String) {
        throw const GlossLatticeValidationException(
          'lattice_websocket_path must be a string in a lattice session',
        );
      }
      _validateWebsocketPath(rawPath, sessionId, 'lattice_websocket_path');
      if (rawPath != websocketPath) {
        throw const GlossLatticeValidationException(
          'lattice_websocket_path must equal websocket_path',
        );
      }
      latticeWebsocketPath = rawPath;
    }

    final createdAt = _expectAwareDateTime(json['created_at'], 'created_at');
    final expiresAt = _expectAwareDateTime(json['expires_at'], 'expires_at');
    if (!expiresAt.isAfter(createdAt)) {
      throw const GlossLatticeValidationException(
        'expires_at must be later than created_at',
      );
    }

    _expectLiteral(
      json['lattice_schema_version'],
      'lattice_schema_version',
      GlossLatticeContract.schemaVersion,
    );
    _expectLiteral(
      json['max_lattice_message_bytes'],
      'max_lattice_message_bytes',
      GlossLatticeContract.maxMessageBytes,
    );
    _expectLiteral(
      json['max_lattice_slots'],
      'max_lattice_slots',
      GlossLatticeContract.maxSlots,
    );
    _expectLiteral(
      json['max_candidates_per_slot'],
      'max_candidates_per_slot',
      GlossLatticeContract.maxCandidatesPerSlot,
    );

    final rawLayout = json['layout'];
    Map<String, dynamic>? layout;
    if (rawLayout != null) {
      if (rawLayout is! Map ||
          rawLayout.keys.any((Object? key) => key is! String)) {
        throw const GlossLatticeValidationException(
          'layout must be a JSON object or null',
        );
      }
      layout = Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(rawLayout),
      );
    }
    final maxBatchFrames = _expectOptionalInt(
      json['max_batch_frames'],
      'max_batch_frames',
      minimum: 1,
      maximum: 32,
    );
    final targetFps = _expectOptionalInt(
      json['target_fps'],
      'target_fps',
      minimum: 1,
      maximum: 60,
    );

    if ((isLatticeOnlyShape || isNullableCompatibilityShape) &&
        (layout != null || maxBatchFrames != null || targetFps != null)) {
      throw const GlossLatticeValidationException(
        'lattice-only response must not populate landmark-mode limits',
      );
    }
    if (isFrozenShape &&
        (layout == null || maxBatchFrames == null || targetFps == null)) {
      throw const GlossLatticeValidationException(
        'frozen response must populate its legacy landmark compatibility '
        'fields',
      );
    }

    return GlossLatticeSessionCreateResponse._(
      sessionId: sessionId,
      streamToken: streamToken,
      websocketPath: websocketPath,
      createdAt: createdAt,
      expiresAt: expiresAt,
      latticeWebsocketPath: latticeWebsocketPath,
      layout: layout,
      maxBatchFrames: maxBatchFrames,
      targetFps: targetFps,
    );
  }
}

bool _sameKeys(Set<String> actual, Set<String> expected) =>
    actual.length == expected.length && actual.containsAll(expected);

String _expectString(Object? value, String path) {
  if (value is! String) {
    throw GlossLatticeValidationException('$path must be a string');
  }
  return value;
}

void _expectLiteral(Object? value, String path, Object expected) {
  if (value.runtimeType != expected.runtimeType || value != expected) {
    throw GlossLatticeValidationException('$path must equal $expected');
  }
}

void _validateLength(
  String value,
  String path, {
  required int minimum,
  required int maximum,
}) {
  if (value.length < minimum || value.length > maximum) {
    throw GlossLatticeValidationException(
      '$path length must be between $minimum and $maximum',
    );
  }
}

void _validateWebsocketPath(String value, String sessionId, String path) {
  final uri = Uri.tryParse(value);
  final expected = '/v1/sessions/$sessionId/lattices';
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      value != expected) {
    throw GlossLatticeValidationException(
      '$path must equal the relative path $expected',
    );
  }
}

DateTime _expectAwareDateTime(Object? value, String path) {
  if (value is! String ||
      !RegExp(r'(?:[zZ]|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw GlossLatticeValidationException(
      '$path must be an ISO-8601 datetime with a timezone',
    );
  }
  try {
    return DateTime.parse(value).toUtc();
  } on FormatException {
    throw GlossLatticeValidationException(
      '$path must be an ISO-8601 datetime with a timezone',
    );
  }
}

int? _expectOptionalInt(
  Object? value,
  String path, {
  required int minimum,
  required int maximum,
}) {
  if (value == null) return null;
  if (value is! int || value < minimum || value > maximum) {
    throw GlossLatticeValidationException(
      '$path must be an integer between $minimum and $maximum or null',
    );
  }
  return value;
}
