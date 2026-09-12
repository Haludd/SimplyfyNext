import '../contracts/gloss_lattice.dart';
import '../contracts/gloss_lattice_session.dart';

/// Non-secret Phase 4 client configuration.
///
/// Values are supplied with `--dart-define` (or a platform flavor), never
/// committed as source constants. Bearer tokens are negotiated at runtime and
/// are intentionally not represented by this class.
final class BppClientConfig {
  BppClientConfig({
    required Uri httpsBaseUri,
    required Uri wssBaseUri,
    required this.language,
    required this.producer,
    required this.client,
    required this.detector,
    this.sessionTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 15),
    this.responseTimeout = const Duration(seconds: 60),
    this.maxRetries = 3,
  }) : httpsBaseUri = _validateOrigin(httpsBaseUri, 'httpsBaseUri', 'https'),
       wssBaseUri = _validateOrigin(wssBaseUri, 'wssBaseUri', 'wss') {
    if (this.httpsBaseUri.host != this.wssBaseUri.host ||
        (this.httpsBaseUri.hasPort &&
            this.wssBaseUri.hasPort &&
            this.httpsBaseUri.port != this.wssBaseUri.port) ||
        (this.httpsBaseUri.hasPort != this.wssBaseUri.hasPort &&
            !_sameDefaultSecurePort(this.httpsBaseUri, this.wssBaseUri))) {
      throw ArgumentError(
        'HTTPS and WSS configuration must point to the same origin.',
      );
    }
    if (maxRetries < 0 || maxRetries > 5) {
      throw ArgumentError.value(maxRetries, 'maxRetries', 'must be 0 through 5');
    }
    _validateDuration(sessionTimeout, 'sessionTimeout');
    _validateDuration(connectTimeout, 'connectTimeout');
    _validateDuration(responseTimeout, 'responseTimeout');
  }

  /// Returns null when no BPP values were supplied, so local camera-only
  /// development remains possible. A partially supplied configuration throws
  /// a visible error instead of silently falling back to the wrong backend.
  static BppClientConfig? fromEnvironment() {
    const keys = <String, String>{
      'BPP_HTTPS_BASE_URL': String.fromEnvironment('BPP_HTTPS_BASE_URL'),
      'BPP_WSS_BASE_URL': String.fromEnvironment('BPP_WSS_BASE_URL'),
      'BPP_LANGUAGE': String.fromEnvironment('BPP_LANGUAGE'),
      'BPP_CLASSIFIER_ID': String.fromEnvironment('BPP_CLASSIFIER_ID'),
      'BPP_CLASSIFIER_VERSION': String.fromEnvironment(
        'BPP_CLASSIFIER_VERSION',
      ),
      'BPP_CALIBRATION_VERSION': String.fromEnvironment(
        'BPP_CALIBRATION_VERSION',
      ),
      'BPP_VOCABULARY_VERSION': String.fromEnvironment(
        'BPP_VOCABULARY_VERSION',
      ),
      'BPP_CLIENT_PLATFORM': String.fromEnvironment('BPP_CLIENT_PLATFORM'),
      'BPP_CLIENT_VERSION': String.fromEnvironment('BPP_CLIENT_VERSION'),
      'BPP_DETECTOR_NAME': String.fromEnvironment('BPP_DETECTOR_NAME'),
      'BPP_DETECTOR_VERSION': String.fromEnvironment('BPP_DETECTOR_VERSION'),
      'BPP_DETECTOR_DELEGATE': String.fromEnvironment(
        'BPP_DETECTOR_DELEGATE',
      ),
    };
    if (keys.values.every((value) => value.isEmpty)) return null;

    final missing = keys.entries
        .where((entry) => entry.value.trim().isEmpty)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      throw StateError(
        'BPP client configuration is incomplete. Missing: ${missing.join(', ')}',
      );
    }

    final language = switch (keys['BPP_LANGUAGE']!.toLowerCase()) {
      'asl' => GlossLatticeLanguage.asl,
      'sgsl' => GlossLatticeLanguage.sgsl,
      _ => throw StateError('BPP_LANGUAGE must be "asl" or "sgsl".'),
    };

    return BppClientConfig(
      httpsBaseUri: Uri.parse(keys['BPP_HTTPS_BASE_URL']!),
      wssBaseUri: Uri.parse(keys['BPP_WSS_BASE_URL']!),
      language: language,
      producer: GlossLatticeProducer(
        classifierId: keys['BPP_CLASSIFIER_ID']!,
        classifierVersion: keys['BPP_CLASSIFIER_VERSION']!,
        calibrationVersion: keys['BPP_CALIBRATION_VERSION']!,
        vocabularyVersion: keys['BPP_VOCABULARY_VERSION']!,
      ),
      client: GlossLatticeClientDescriptor(
        platform: _platformFromWireValue(keys['BPP_CLIENT_PLATFORM']!),
        appVersion: keys['BPP_CLIENT_VERSION']!,
        deviceModel: _optionalEnvironment('BPP_DEVICE_MODEL'),
      ),
      detector: GlossLatticeDetectorDescriptor(
        name: keys['BPP_DETECTOR_NAME']!,
        version: keys['BPP_DETECTOR_VERSION']!,
        delegate: _delegateFromWireValue(keys['BPP_DETECTOR_DELEGATE']!),
      ),
      sessionTimeout: _secondsFromEnvironment(
        'BPP_SESSION_TIMEOUT_SECONDS',
        15,
      ),
      connectTimeout: _secondsFromEnvironment(
        'BPP_CONNECT_TIMEOUT_SECONDS',
        15,
      ),
      responseTimeout: _secondsFromEnvironment(
        'BPP_RESPONSE_TIMEOUT_SECONDS',
        60,
      ),
      maxRetries: int.fromEnvironment('BPP_MAX_RETRIES', defaultValue: 3),
    );
  }

  final Uri httpsBaseUri;
  final Uri wssBaseUri;
  final GlossLatticeLanguage language;
  final GlossLatticeProducer producer;
  final GlossLatticeClientDescriptor client;
  final GlossLatticeDetectorDescriptor detector;
  final Duration sessionTimeout;
  final Duration connectTimeout;
  final Duration responseTimeout;
  final int maxRetries;

  GlossLatticeSessionCreateRequest toSessionRequest() =>
      GlossLatticeSessionCreateRequest(
        language: language,
        client: client,
        detector: detector,
        producer: producer,
      );
}

bool _sameDefaultSecurePort(Uri https, Uri wss) =>
    (!https.hasPort || https.port == 443) && (!wss.hasPort || wss.port == 443);

Uri _validateOrigin(Uri value, String name, String scheme) {
  if (!value.isAbsolute ||
      value.scheme != scheme ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment ||
      (value.path.isNotEmpty && value.path != '/')) {
    throw ArgumentError.value(
      value,
      name,
      'must be an absolute $scheme origin without credentials, path, query, '
          'or fragment',
    );
  }
  return value.replace(path: '');
}

String? _optionalEnvironment(String name) {
  const values = <String, String>{
    'BPP_DEVICE_MODEL': String.fromEnvironment('BPP_DEVICE_MODEL'),
  };
  final value = values[name]?.trim() ?? '';
  return value.isEmpty ? null : value;
}

GlossLatticeClientPlatform _platformFromWireValue(String value) => switch (
  value.toLowerCase()
) {
  'android' => GlossLatticeClientPlatform.android,
  'ios' => GlossLatticeClientPlatform.ios,
  'test' => GlossLatticeClientPlatform.test,
  'web' => throw StateError(
    'Browser BPP WebSocket authentication is not supported by the current '
    'bearer-header contract.',
  ),
  _ => throw StateError(
    'BPP_CLIENT_PLATFORM must be "android", "ios", or "test".',
  ),
};

GlossLatticeDetectorDelegate _delegateFromWireValue(String value) => switch (
  value.toLowerCase()
) {
  'cpu' => GlossLatticeDetectorDelegate.cpu,
  'gpu' => GlossLatticeDetectorDelegate.gpu,
  'nnapi' => GlossLatticeDetectorDelegate.nnapi,
  'core_ml' => GlossLatticeDetectorDelegate.coreMl,
  'unknown' => GlossLatticeDetectorDelegate.unknown,
  _ => throw StateError(
    'BPP_DETECTOR_DELEGATE must be cpu, gpu, nnapi, core_ml, or unknown.',
  ),
};

Duration _secondsFromEnvironment(String name, int defaultValue) {
  final value = switch (name) {
    'BPP_SESSION_TIMEOUT_SECONDS' => const int.fromEnvironment(
      'BPP_SESSION_TIMEOUT_SECONDS',
      defaultValue: 15,
    ),
    'BPP_CONNECT_TIMEOUT_SECONDS' => const int.fromEnvironment(
      'BPP_CONNECT_TIMEOUT_SECONDS',
      defaultValue: 15,
    ),
    'BPP_RESPONSE_TIMEOUT_SECONDS' => const int.fromEnvironment(
      'BPP_RESPONSE_TIMEOUT_SECONDS',
      defaultValue: 60,
    ),
    _ => defaultValue,
  };
  return Duration(seconds: value);
}

void _validateDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
}
