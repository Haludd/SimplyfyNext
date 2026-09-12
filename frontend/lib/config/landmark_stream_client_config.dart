import '../contracts/landmark_stream.dart';

/// Runtime configuration for the server-owned landmark pipeline.
///
/// This is deliberately separate from the older GlossLattice configuration:
/// the server-side classifier receives raw `landmark_batch` messages and does
/// not ask the client to provide classifier/producer identifiers.
///
/// Enable it explicitly with `--dart-define=SIGNBRIDGE_STREAM_ENABLED=true`.
/// All connection and detector values stay in the environment/flavor rather
/// than becoming source constants.
final class LandmarkStreamClientConfig {
  LandmarkStreamClientConfig({
    required this.httpsBaseUri,
    required this.websocketBaseUri,
    required this.sessionRequest,
    required this.camera,
    this.subjectId = 'subject-0',
    this.sessionTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 15),
    this.responseTimeout = const Duration(seconds: 60),
  }) {
    if (subjectId.trim().isEmpty) {
      throw ArgumentError.value(subjectId, 'subjectId', 'must not be empty');
    }
  }

  static LandmarkStreamClientConfig? fromEnvironment() {
    const enabled = bool.fromEnvironment(
      'SIGNBRIDGE_STREAM_ENABLED',
      defaultValue: false,
    );
    if (!enabled) return null;

    const values = <String, String>{
      'BPP_HTTPS_BASE_URL': String.fromEnvironment('BPP_HTTPS_BASE_URL'),
      'BPP_WSS_BASE_URL': String.fromEnvironment('BPP_WSS_BASE_URL'),
      'BPP_LANGUAGE': String.fromEnvironment('BPP_LANGUAGE'),
      'BPP_CLIENT_PLATFORM': String.fromEnvironment('BPP_CLIENT_PLATFORM'),
      'BPP_CLIENT_VERSION': String.fromEnvironment('BPP_CLIENT_VERSION'),
      'BPP_DEVICE_MODEL': String.fromEnvironment('BPP_DEVICE_MODEL'),
      'BPP_DETECTOR_NAME': String.fromEnvironment('BPP_DETECTOR_NAME'),
      'BPP_DETECTOR_VERSION': String.fromEnvironment('BPP_DETECTOR_VERSION'),
      'BPP_DETECTOR_DELEGATE': String.fromEnvironment(
        'BPP_DETECTOR_DELEGATE',
      ),
      'BPP_SUBJECT_ID': String.fromEnvironment('BPP_SUBJECT_ID'),
    };
    final missing = values.entries
        .where((entry) => entry.key != 'BPP_DEVICE_MODEL' && entry.key != 'BPP_SUBJECT_ID')
        .where((entry) => entry.value.trim().isEmpty)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      throw StateError(
        'Landmark stream configuration is incomplete. Missing: ${missing.join(', ')}',
      );
    }

    return LandmarkStreamClientConfig(
      httpsBaseUri: Uri.parse(values['BPP_HTTPS_BASE_URL']!),
      websocketBaseUri: Uri.parse(values['BPP_WSS_BASE_URL']!),
      sessionRequest: LandmarkStreamSessionCreateRequest(
        language: values['BPP_LANGUAGE']!.trim().toLowerCase(),
        client: LandmarkStreamClientDescriptor(
          platform: _platform(values['BPP_CLIENT_PLATFORM']!),
          appVersion: values['BPP_CLIENT_VERSION']!.trim(),
          deviceModel: _optional(values['BPP_DEVICE_MODEL']),
        ),
        detector: LandmarkStreamDetectorDescriptor(
          name: values['BPP_DETECTOR_NAME']!.trim(),
          version: values['BPP_DETECTOR_VERSION']!.trim(),
          delegate: _delegate(values['BPP_DETECTOR_DELEGATE']!),
        ),
      ),
      camera: LandmarkCameraGeometry(
        sourceWidth: int.fromEnvironment('BPP_CAMERA_WIDTH', defaultValue: 1280),
        sourceHeight: int.fromEnvironment('BPP_CAMERA_HEIGHT', defaultValue: 720),
        rotationDegrees: int.fromEnvironment(
          'BPP_CAMERA_ROTATION_DEGREES',
          defaultValue: 0,
        ),
        mirroredInput: bool.fromEnvironment(
          'BPP_CAMERA_MIRRORED_INPUT',
          defaultValue: true,
        ),
      ),
      subjectId: _optional(values['BPP_SUBJECT_ID']) ?? 'subject-0',
      sessionTimeout: _seconds(
        const int.fromEnvironment('BPP_SESSION_TIMEOUT_SECONDS', defaultValue: 15),
      ),
      connectTimeout: _seconds(
        const int.fromEnvironment('BPP_CONNECT_TIMEOUT_SECONDS', defaultValue: 15),
      ),
      responseTimeout: _seconds(
        const int.fromEnvironment('BPP_RESPONSE_TIMEOUT_SECONDS', defaultValue: 60),
      ),
    );
  }

  final Uri httpsBaseUri;
  final Uri websocketBaseUri;
  final LandmarkStreamSessionCreateRequest sessionRequest;
  final LandmarkCameraGeometry camera;
  final String subjectId;
  final Duration sessionTimeout;
  final Duration connectTimeout;
  final Duration responseTimeout;
}

LandmarkStreamClientPlatform _platform(String value) => switch (value.trim().toLowerCase()) {
  'android' => LandmarkStreamClientPlatform.android,
  'ios' => LandmarkStreamClientPlatform.ios,
  'test' => LandmarkStreamClientPlatform.test,
  'web' => throw StateError(
      'The current bearer-header WebSocket contract does not support web clients.',
    ),
  _ => throw StateError(
      'BPP_CLIENT_PLATFORM must be android, ios, or test for this backend.',
    ),
};

LandmarkStreamDetectorDelegate _delegate(String value) => switch (value.trim().toLowerCase()) {
  'cpu' => LandmarkStreamDetectorDelegate.cpu,
  'gpu' => LandmarkStreamDetectorDelegate.gpu,
  'nnapi' => LandmarkStreamDetectorDelegate.nnapi,
  'core_ml' => LandmarkStreamDetectorDelegate.coreMl,
  'unknown' => LandmarkStreamDetectorDelegate.unknown,
  _ => throw StateError(
      'BPP_DETECTOR_DELEGATE must be cpu, gpu, nnapi, core_ml, or unknown.',
    ),
};

String? _optional(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

Duration _seconds(int value) {
  if (value <= 0) throw StateError('Stream timeout values must be positive.');
  return Duration(seconds: value);
}
