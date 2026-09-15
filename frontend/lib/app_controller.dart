import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'config/landmark_stream_client_config.dart';
import 'models/asl_recognition_models.dart';
import 'contracts/landmark_stream.dart';
import 'contracts/translated_sign_utterance.dart';
import 'models/face_tracking_models.dart';
import 'models/tracking_models.dart';
import 'models/hand_tracking_models.dart';
import 'models/speech_recognition_models.dart';
import 'services/device_access_service.dart';
import 'services/asl_recognizer_bridge.dart';
import 'services/asl_label_to_english.dart';
import 'services/local_state_service.dart';
import 'services/local_sign_sequence.dart';
import 'services/personal_sign_matcher.dart';
import 'services/sign_analysis_service.dart';
import 'services/speech_to_text_service.dart';
import 'services/text_to_speech_service.dart';
import 'services/tracking_service.dart';
import 'services/sign_boundary_detector.dart';
import 'services/server_landmark_stream_integration.dart';
import 'services/translated_sign_utterance_submission_service.dart';
import 'services/web_hand_tracker_bridge.dart';

enum SignBridgePage { onboarding, live, dictionary, settings }

enum ViewMode { raw, wireframe, clean }

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController(
    this._localState,
    this.tracking,
    this.devices, {
    SpeechToTextService? speechToText,
    TextToSpeechService? textToSpeech,
    AslRecognizerBridge? aslRecognizer,
    TranslatedSignUtteranceGateway? utteranceSubmission,
    String Function()? messageIdGenerator,
    this.utteranceIdleTimeout = const Duration(milliseconds: 1500),
  }) : speechToText = speechToText ?? SpeechToTextService(),
       textToSpeech = textToSpeech ?? TextToSpeechService(),
       _aslRecognizer = aslRecognizer ?? AslRecognizerBridge(),
       _utteranceSubmission =
           utteranceSubmission ??
           TranslatedSignUtteranceSubmissionService.fromEnvironment(),
       _messageIdGenerator = messageIdGenerator ?? _newUuidV4 {
    if (utteranceIdleTimeout <= Duration.zero) {
      throw ArgumentError.value(
        utteranceIdleTimeout,
        'utteranceIdleTimeout',
        'must be positive',
      );
    }
    backendStatus =
        'Local recognition · words stay on this device until Translate';
    _trackingSubscription = tracking.frames.listen(_onTrackingFrame);
    this.speechToText.addListener(_onSpeechToTextChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreState());
  }

  final LocalStateService _localState;
  final TrackingService tracking;
  final DeviceAccessService devices;
  final SpeechToTextService speechToText;
  final TextToSpeechService textToSpeech;
  final AslRecognizerBridge _aslRecognizer;
  final TranslatedSignUtteranceGateway _utteranceSubmission;
  final String Function() _messageIdGenerator;
  final Duration utteranceIdleTimeout;
  final SignAnalysisService signAnalyzer = SignAnalysisService();
  final SimulatedSignSequenceApiClient simulator =
      SimulatedSignSequenceApiClient();
  final SignBoundaryDetector _signBoundaryDetector = SignBoundaryDetector();
  final PersonalSignMatcher _personalSignMatcher = const PersonalSignMatcher();
  final AslLabelToEnglish _englishTranslator = const AslLabelToEnglish();
  final String sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';

  late final StreamSubscription<LandmarkFrame> _trackingSubscription;
  Timer? _frameNotifyTimer;
  Timer? _utteranceIdleTimer;
  SignBridgePage page = SignBridgePage.onboarding;
  ViewMode viewMode = ViewMode.wireframe;
  int calibrationStep = 1;
  bool calibrated = false;
  bool audioEnabled = true;
  bool isPaused = false;
  bool isUnregisteredSign = false;
  List<CustomSign> customSigns = <CustomSign>[];
  SignAnalysisResult? latestAnalysis;

  /// Contract-safe English words held locally until the signer finishes the
  /// complete utterance. They are never sent one sign at a time.
  final List<_BufferedTranslatedWord> _utteranceWords =
      <_BufferedTranslatedWord>[];
  TranslatedSignUtterance? _pendingUtterance;
  String? _draftMessageId;
  bool _utteranceSubmissionInFlight = false;

  List<String> get translatedWords =>
      List<String>.unmodifiable(_utteranceWords.map((word) => word.word));

  @Deprecated('Use translatedWords; v1 sends English words, not glosses.')
  List<String> get glosses => translatedWords;

  int get translatedWordCount => _utteranceWords.length;
  bool get hasTranslatedWords => _utteranceWords.isNotEmpty;
  bool get isUtteranceSubmissionConfigured => _utteranceSubmission.isConfigured;
  bool get isUtteranceSubmissionInFlight => _utteranceSubmissionInFlight;
  bool get hasPendingUtteranceRetry => _pendingUtterance != null;
  bool get canCommitTranslatedUtterance =>
      !_utteranceSubmissionInFlight &&
      (_pendingUtterance != null || _utteranceWords.isNotEmpty);
  bool get canClearTranslatedUtterance =>
      _pendingUtterance == null && _utteranceWords.isNotEmpty;
  String get utteranceIdleTimeoutLabel {
    final seconds = utteranceIdleTimeout.inMilliseconds / 1000;
    final value = seconds == seconds.roundToDouble()
        ? seconds.toStringAsFixed(0)
        : seconds.toStringAsFixed(1);
    return '$value second${seconds == 1 ? '' : 's'}';
  }

  /// JSON that would be sent if the signer presses Translate now. It is safe
  /// to show in the UI: participant credentials are an HTTP header and never
  /// appear in this contract object.
  String? get translatedUtterancePreviewJson {
    if (_utteranceWords.isEmpty && _pendingUtterance == null) return null;
    try {
      final utterance =
          _pendingUtterance ??
          _buildFinalUtterance(
            TranslatedSignUtteranceCompletionReason.userCommit,
          );
      return const JsonEncoder.withIndent('  ').convert(utterance.toJson());
    } on Object {
      return null;
    }
  }

  /// The last completed result stays visible while the next sign is captured.
  SignAnalysisResult? get visibleAnalysis => latestAnalysis;

  /// The most recently completed sign. Each item is one LandmarkFrame; this
  /// is the handoff for the next processing stage.
  ///
  /// NEXT TEAMMATE: after a sign pause is detected automatically, access the
  /// captured sequence with:
  ///
  ///   final frames = controller.lastSignFrames;
  ///
  /// Then read coordinates from `frame.hands`, `frame.poseLandmarks`, and
  /// `frame.faceUpperLandmarks`/`frame.faceMouthLandmarks`. If serialized data
  /// is needed, use `controller.lastSignJson` or `frame.toJson()`.
  List<LandmarkFrame> lastSignFrames = const <LandmarkFrame>[];

  /// Compatibility view for the existing backend/lattice integration.
  List<LandmarkFrame> get lastUtteranceFrames => lastSignFrames;
  bool analysisInFlight = false;
  int _localRecognitionsInFlight = 0;
  int _recognitionGeneration = 0;
  bool _disposed = false;
  bool _captureFinishInFlight = false;
  bool _teachingPersonalSign = false;
  String backendStatus = 'Offline simulation · no backend configured';
  String selectedLanguage = 'ASL';
  String? backendActivityState;
  String? _lastSpokenAnalysisKey;
  ServerLandmarkStreamIntegration? _serverLandmarkStream;
  bool _serverOwnsUtteranceLifecycle = false;
  bool _backendConnecting = false;
  String? lastBackendBatchJson;
  int backendBatchesSent = 0;
  int backendFramesSent = 0;

  bool get isBackendConnected =>
      _serverLandmarkStream != null && !_serverLandmarkStream!.isClosed;
  bool get isBackendConnecting => _backendConnecting;
  bool get serverOwnsUtteranceLifecycle => _serverOwnsUtteranceLifecycle;

  void _onSpeechToTextChanged() => notifyListeners();

  void _setLatestAnalysis(SignAnalysisResult analysis) {
    latestAnalysis = analysis;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelUtteranceAutoCommit();
      unawaited(speechToText.stopListening());
      unawaited(textToSpeech.stop());
    }
  }

  void _onTrackingFrame(LandmarkFrame frame) {
    if (!_serverOwnsUtteranceLifecycle && !isPaused && !_teachingPersonalSign) {
      // In local mode signs are automatic. In server mode the Railway
      // segmenter owns this lifecycle and the client only streams frames.
      if ((!analysisInFlight || _usesLocalAslCapture) &&
          !_captureFinishInFlight &&
          !tracking.isCapturingSign &&
          _hasCaptureSignal(frame)) {
        _signBoundaryDetector.reset();
        tracking.beginSign();
        lastSignFrames = const <LandmarkFrame>[];
        if (_usesLocalAslCapture) unawaited(_aslRecognizer.beginCapture());
        // Keep the completed word on screen while the next sign is being
        // captured. It will be replaced only by the next completed result.
        backendStatus = _usesLocalAslCapture
            ? 'Listening · collecting local ASL landmarks'
            : 'Listening · capturing one sign automatically';
      }

      if (tracking.isCapturingSign && !_captureFinishInFlight) {
        final boundaryReached = _signBoundaryDetector.update(frame);
        if (_signBoundaryDetector.hasObservedActivity) {
          _cancelUtteranceAutoCommit();
        }
        if (boundaryReached) {
          unawaited(analyzeSign(automatic: true));
        }
      } else if (!tracking.isCapturingSign) {
        _signBoundaryDetector.reset();
      }
    }

    // The camera stream can be continuous, but rebuilding the entire Flutter
    // page for every detector frame is expensive on the web. Keep the latest
    // frame immediately in the tracking service and repaint the UI at a
    // steady 20 FPS.
    if (_frameNotifyTimer != null) return;
    _frameNotifyTimer = Timer(const Duration(milliseconds: 33), () {
      _frameNotifyTimer = null;
      notifyListeners();
    });
  }

  bool _hasCaptureSignal(LandmarkFrame frame) =>
      frame.trackingConfidence >= .5 &&
      (frame.subjectTracking == null ||
          (frame.subjectTracking!.locked && frame.subjectTracking!.visible)) &&
      (frame.handsVisible || frame.leftHandVisible || frame.rightHandVisible);

  bool get _usesLocalAslCapture =>
      !_serverOwnsUtteranceLifecycle &&
      selectedLanguage.trim().toUpperCase() == 'ASL' &&
      _aslRecognizer.isSupported;

  bool get _usesLocalPersonalCapture =>
      !_serverOwnsUtteranceLifecycle &&
      customSigns.any(
        (sign) =>
            sign.hasEnoughSamples &&
            sign.language.toUpperCase() ==
                selectedLanguage.trim().toUpperCase(),
      );

  LandmarkFrame? get latestFrame => tracking.latestFrame;
  AlignmentResult get alignment => AlignmentEvaluator().evaluate(
    latestFrame ??
        LandmarkFrame(timestamp: DateTime.fromMillisecondsSinceEpoch(0)),
  );
  double get confidence => latestFrame?.trackingConfidence ?? 0;
  String get confidenceWindowLabel => tracking.confidenceWindow.windowLabel;
  String get trackingStatus => tracking.status;
  int get utteranceFrameCount => tracking.utteranceFrameCount;
  bool get isCapturingUtterance => tracking.isCapturingUtterance;
  int get signFrameCount => tracking.signFrameCount;
  bool get isCapturingSign => tracking.isCapturingSign;

  /// Speech captions are optional and do not interrupt landmark tracking.
  Future<void> toggleSpeechCaptioning() async {
    switch (speechToText.status) {
      case SpeechServiceStatus.initializing:
      case SpeechServiceStatus.starting:
      case SpeechServiceStatus.listening:
        await speechToText.stopListening();
        return;
      case SpeechServiceStatus.stopping:
        return;
      case SpeechServiceStatus.uninitialized:
      case SpeechServiceStatus.ready:
      case SpeechServiceStatus.unavailable:
      case SpeechServiceStatus.error:
        await speechToText.startListening(
          listenFor: const Duration(minutes: 1),
          pauseFor: const Duration(seconds: 3),
        );
        return;
    }
  }

  Future<void> stopSpeechCaptioning() => speechToText.stopListening();

  void clearSpeechCaption() => speechToText.clearTranscript();

  /// Connects the camera stream to Railway's normaliser, segmenter, and
  /// classifier. The app does not run a second local classifier when this
  /// succeeds: each [LandmarkFrame] is encoded as a backend `landmark_batch`.
  Future<bool> connectToBackend(LandmarkStreamClientConfig config) async {
    if (_serverLandmarkStream != null) return true;
    if (_backendConnecting) return false;
    _backendConnecting = true;
    backendStatus = 'Connecting to backend...';
    notifyListeners();
    try {
      final integration = await ServerLandmarkStreamIntegration.connect(
        httpsBaseUri: config.httpsBaseUri,
        websocketBaseUri: config.websocketBaseUri,
        request: config.sessionRequest,
        tracking: tracking,
        camera: config.camera,
        subjectId: config.subjectId,
        sessionTimeout: config.sessionTimeout,
        connectTimeout: config.connectTimeout,
        responseTimeout: config.responseTimeout,
        onEvent: acceptBackendEvent,
        onBatchSent: _recordBackendBatch,
        onError: (error, _) {
          backendStatus = 'Backend stream error · ${_shortError(error)}';
          notifyListeners();
        },
      );
      try {
        _serverLandmarkStream = integration;
        _serverOwnsUtteranceLifecycle = true;
        backendStatus = 'Backend connected · waiting for landmarks';
        if (devices.cameraReady) {
          await integration.start(startTracking: false);
        }
      } on Object {
        _serverLandmarkStream = null;
        _serverOwnsUtteranceLifecycle = false;
        await integration.close();
        rethrow;
      }
      notifyListeners();
      return true;
    } on Object catch (error) {
      backendStatus = 'Backend unavailable · ${_shortError(error)}';
      notifyListeners();
      return false;
    } finally {
      _backendConnecting = false;
      notifyListeners();
    }
  }

  /// Stores the last acknowledged wire payload for local debugging. This is
  /// never sent anywhere extra and contains no bearer token.
  void _recordBackendBatch(LandmarkBatch batch) {
    final wire = batch.toWireJson();
    lastBackendBatchJson = JsonEncoder.withIndent('  ')
        .convert(jsonDecode(wire));
    backendBatchesSent += 1;
    backendFramesSent += batch.frames.length;
    notifyListeners();
  }

  /// Closes the negotiated stream and releases its short-lived backend
  /// session. The camera can continue in local mode after this call.
  Future<void> disconnectFromBackend() async {
    final integration = _serverLandmarkStream;
    _serverLandmarkStream = null;
    _serverOwnsUtteranceLifecycle = false;
    if (integration == null) return;
    try {
      await integration.close();
      backendStatus = 'Local capture only · no backend request';
    } on Object catch (error) {
      backendStatus =
          'Backend disconnected with cleanup warning · ${_shortError(error)}';
    } finally {
      notifyListeners();
    }
  }

  /// Reads a completed classifier caption when one is available. In server
  /// mode the text comes from the backend's `tts_text` field.
  Future<void> readCaptionAloud() async {
    if (!audioEnabled) return;
    final analysis = latestAnalysis;
    final text = analysis?.ttsText ?? analysis?.caption;
    if (text == null || text.trim().isEmpty) return;
    await textToSpeech.speak(text);
  }

  /// Applies a validated backend event to the existing appTesting UI.
  ///
  /// The transport layer remains separate from the widgets. The teammate who
  /// owns the Stage 5/6 classifier can call this with
  /// `receipt.terminalEvent` (or with each activity event) and the live
  /// caption, repair action, confidence, gloss trace, and local TTS will use
  /// the backend result without changing the camera UI.
  void acceptBackendEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'activity') {
      final state = event['state'];
      if (state is String) backendActivityState = state;
      if (state == 'processing') {
        analysisInFlight = true;
        backendStatus = 'Backend processing sign';
      } else if (state == 'idle' && !analysisInFlight) {
        backendStatus = 'Backend ready';
      }
      notifyListeners();
      return;
    }
    if (type == 'ack' || type == 'lattice_ack') {
      // An acknowledgement is admission only, not a completed translation.
      backendStatus = event['disposition'] == 'cached'
          ? 'Backend replay accepted · waiting for result'
          : 'Backend accepted · waiting for result';
      notifyListeners();
      return;
    }
    final isResult = type == 'utterance_result' || type == 'lattice_result';
    final isRepair =
        type == 'repair_required' || type == 'lattice_repair_required';
    if (!isResult && !isRepair) {
      if (type == 'error') {
        backendStatus = 'Backend error · ${event['message'] ?? 'unavailable'}';
        analysisInFlight = false;
        notifyListeners();
      }
      return;
    }

    final result = SignAnalysisResult.fromJson(event);
    _setLatestAnalysis(result);
    analysisInFlight = false;
    backendStatus = isRepair
        ? 'Repair required · ${result.repairAction ?? 'ask_repeat'}'
        : 'Backend result ready';
    notifyListeners();

    // A terminal confident result is spoken once per lattice. Repairs never
    // trigger speech because they contain no caption or tts_text.
    if (isResult && audioEnabled) {
      final key = '${result.utteranceId}:${event['lattice_seq'] ?? ''}';
      if (key != _lastSpokenAnalysisKey) {
        _lastSpokenAnalysisKey = key;
        unawaited(readCaptionAloud());
      }
    }
  }

  /// Starts one sign capture. Normal UI capture starts automatically when a
  /// usable hand signal appears.
  void startSign() {
    if (_serverOwnsUtteranceLifecycle) {
      backendStatus = 'Backend captures signs automatically';
      notifyListeners();
      return;
    }
    if ((!_usesLocalAslCapture && analysisInFlight) ||
        _captureFinishInFlight ||
        tracking.isCapturingSign) {
      return;
    }
    if (latestFrame == null) {
      backendStatus = 'Start the camera before capturing a sign';
      notifyListeners();
      return;
    }
    _signBoundaryDetector.reset();
    tracking.beginSign();
    lastSignFrames = const <LandmarkFrame>[];
    if (_usesLocalAslCapture) unawaited(_aslRecognizer.beginCapture());
    // A manual capture should not make the previous sign disappear before
    // there is a newer completed result to show.
    backendStatus = _usesLocalAslCapture
        ? 'Capturing landmark clip for local ASL model'
        : 'Capturing one sign locally';
    notifyListeners();
  }

  /// Older callers can still start the same single-sign capture.
  @Deprecated('Use startSign')
  void startUtterance() => startSign();

  /// JSON-ready handoff for the next processing stage. The source of truth is
  /// still [lastSignFrames], not this serialized convenience view.
  List<Map<String, dynamic>> get lastSignJson =>
      lastSignFrames.map((frame) => frame.toJson()).toList(growable: false);

  @Deprecated('Use lastSignJson')
  List<Map<String, dynamic>> get lastUtteranceJson => lastSignJson;

  void setLanguage(String language) {
    if (selectedLanguage != language) {
      if (_pendingUtterance != null) {
        backendStatus =
            'Retry the final utterance before switching sign languages';
        notifyListeners();
        return;
      }
      _recognitionGeneration += 1;
      unawaited(_aslRecognizer.reset());
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      _signBoundaryDetector.reset();
      _cancelUtteranceAutoCommit();
      _utteranceWords.clear();
      _draftMessageId = null;
    }
    selectedLanguage = language;
    notifyListeners();
  }

  Future<void> _restoreState() async {
    calibrated = await _localState.isCalibrated();
    final savedSigns = await _localState.loadCustomSigns();
    customSigns = savedSigns;
    if (calibrated) {
      page = SignBridgePage.live;
    }
    notifyListeners();
  }

  void navigate(SignBridgePage destination) {
    if (!calibrated && destination != SignBridgePage.onboarding) {
      page = SignBridgePage.onboarding;
    } else {
      page = destination;
    }
    if (page != SignBridgePage.live) {
      unawaited(speechToText.stopListening());
    }
    notifyListeners();
  }

  Future<void> requestCamera() async {
    await devices.enableCamera();
    if (devices.cameraReady) {
      try {
        if (kIsWeb) await setWebCameraFacing(devices.webFacingMode);
        await tracking.start();
        final integration = _serverLandmarkStream;
        if (integration != null && !integration.isStarted) {
          await integration.start(startTracking: false);
        }
      } catch (_) {
        if (kIsWeb) {
          devices.markWebCameraUnavailable(
            'Camera unavailable · allow access and retry',
          );
        }
      }
    }
    notifyListeners();
  }

  /// Turns the camera and landmark stream off, or starts them again when the
  /// camera is currently disabled.
  Future<void> toggleCamera() async {
    _recognitionGeneration += 1;
    if (!devices.cameraReady) {
      await requestCamera();
      return;
    }

    try {
      final integration = _serverLandmarkStream;
      if (integration != null && integration.isStarted) {
        await integration.stop();
      } else {
        await tracking.stop();
      }
    } finally {
      unawaited(_aslRecognizer.reset());
      await devices.disableCamera();
      notifyListeners();
    }
  }

  /// Releases and starts the camera again. This is useful on web after a
  /// browser tab has suspended the video stream or permission state.
  Future<void> restartCamera() async {
    _recognitionGeneration += 1;
    try {
      final integration = _serverLandmarkStream;
      if (integration != null && integration.isStarted) {
        await integration.stop();
      } else {
        await tracking.stop();
      }
    } catch (_) {
      // Continue to request a fresh stream even if the old stream was already
      // closed by the browser.
    }
    await _aslRecognizer.reset();
    if (kIsWeb) {
      devices.markWebCameraUnavailable('Restarting camera...');
    }
    await requestCamera();
  }

  /// Switches between front and rear cameras and starts a fresh tracking
  /// session so MediaPipe and the local classifier use the selected stream.
  Future<void> switchCamera() async {
    _recognitionGeneration += 1;
    final wasReady = devices.cameraReady;
    if (wasReady) {
      try {
        await tracking.stop();
      } catch (_) {
        // A browser may already have ended the previous track.
      }
      await _aslRecognizer.reset();
      await devices.disableCamera();
    }
    devices.toggleCameraFacing();
    if (kIsWeb) await setWebCameraFacing(devices.webFacingMode);
    if (wasReady) await requestCamera();
    notifyListeners();
  }

  Future<void> analyzeSign({bool automatic = false}) async {
    if (_serverOwnsUtteranceLifecycle) {
      backendStatus = 'Backend is capturing and segmenting signs automatically';
      notifyListeners();
      return;
    }
    final useLocalAslCapture = _usesLocalAslCapture;
    final useLocalPersonalCapture =
        !useLocalAslCapture && _usesLocalPersonalCapture;
    if (_captureFinishInFlight ||
        (!useLocalAslCapture && !useLocalPersonalCapture && analysisInFlight)) {
      return;
    }
    if (!tracking.isCapturingSign) {
      backendStatus = 'Waiting for a tracked hand signal';
      notifyListeners();
      return;
    }
    _captureFinishInFlight = true;
    var captureReleased = false;
    if (useLocalAslCapture) _localRecognitionsInFlight += 1;
    analysisInFlight = true;
    final generation = _recognitionGeneration;
    final language = selectedLanguage;
    backendStatus = 'Recognizing captured sign…';
    notifyListeners();
    try {
      final frames = await tracking.finishSign();
      if (generation != _recognitionGeneration || _disposed) return;
      _signBoundaryDetector.reset();
      lastSignFrames = frames;
      if (frames.isEmpty) {
        await _aslRecognizer.reset();
        backendStatus = 'Waiting for tracked frames';
        return;
      }
      if (useLocalAslCapture) {
        // finishCapture snapshots the browser landmark buffer before its
        // first await. Release the capture boundary while local ONNX
        // inference runs so the next sign can be collected.
        final pendingResult = _aslRecognizer.finishCapture();
        _captureFinishInFlight = false;
        captureReleased = true;
        final result = await pendingResult;
        if (generation != _recognitionGeneration || _disposed) return;
        if (result == null) {
          throw StateError('Local ASL classifier unavailable');
        }
        _acceptLocalRecognition(_preferPersonalSign(result, frames), frames);
        return;
      }
      if (useLocalPersonalCapture) {
        final result = _personalSignRecognition(frames);
        if (result == null) {
          backendStatus =
              'No close personal-sign match · repeat the saved sign clearly';
          return;
        }
        _acceptLocalRecognition(result, frames);
        return;
      }
      final payload = SignSequencePayload(
        sessionId: sessionId,
        sequenceId: 'sequence-${DateTime.now().millisecondsSinceEpoch}',
        language: language,
        startedAt: frames.first.timestamp,
        endedAt: frames.last.timestamp,
        frames: frames,
        lexiconVersion: SignLexicon.version,
      );
      final result = await simulator.analyze(payload);
      if (generation != _recognitionGeneration || _disposed) return;
      _setLatestAnalysis(result);
      backendStatus = 'Local result ready · payload not sent';
    } on Object catch (error) {
      if (generation == _recognitionGeneration && !_disposed) {
        backendStatus = 'Recognition unavailable · ${_shortError(error)}';
      }
    } finally {
      if (useLocalAslCapture) {
        if (_localRecognitionsInFlight > 0) _localRecognitionsInFlight -= 1;
        analysisInFlight = _localRecognitionsInFlight > 0;
      } else {
        analysisInFlight = false;
      }
      if (!captureReleased) _captureFinishInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _acceptLocalRecognition(
    AslRecognitionResult result,
    List<LandmarkFrame> frames,
  ) {
    _setLatestAnalysis(_localAslAnalysis(result));
    if (!result.isRecognized) {
      backendStatus = result.status == 'unavailable'
          ? 'Local ASL model unavailable · ${result.detail ?? 'check the browser model assets'}'
          : switch (result.reason) {
              'too_few_hand_frames' || 'too_few_model_frames' => 'Keep your upper body and signing hand in view for the whole sign',
              'tracking_interrupted' => 'Tracking was interrupted · keep your face and hands in view and retry',
              'no_sign_motion' =>
                'Make one clear sign movement, then pause briefly',
              'capture_too_long' => 'Sign one word, then pause briefly',
              _ => 'No high-confidence ASL word · sign again slowly',
            };
      return;
    }

    final word = result.word!;
    if (_pendingUtterance != null) {
      backendStatus =
          'Final utterance is awaiting retry · no new word was added';
      return;
    }
    try {
      final translation = _englishTranslator.translate(result);
      final producer = _producerFor(result);
      if (_utteranceWords.length + translation.words.length >
          TranslatedSignUtteranceContract.maxWords) {
        backendStatus = 'This utterance already has 64 words · tap Translate before signing more';
        return;
      }
      _draftMessageId ??= _messageIdGenerator();
      for (var index = 0; index < translation.words.length; index += 1) {
        _utteranceWords.add(
          _BufferedTranslatedWord(
            word: translation.words[index],
            confidence: result.confidence,
            producer: producer,
            alternatives: index == 0
                ? translation.alternatives
                : const <EnglishLabelAlternative>[],
          ),
        );
      }
      backendStatus = _utteranceSubmission.isConfigured
          ? 'Captured ${translation.words.join(' ')} · '
                '${_utteranceWords.length} word${_utteranceWords.length == 1 ? '' : 's'} ready · tap Send signs when the sentence is complete'
          : 'Captured ${translation.words.join(' ')} locally · '
                'configure a room to translate the final utterance';
    } on ArgumentError {
      backendStatus =
          'Recognized "$word" locally, but its English translation is unsupported';
      return;
    } on TranslatedSignUtteranceValidationException {
      backendStatus =
          'Recognized personal sign "$word" locally · type it in the conversation to send';
      return;
    }
    if (audioEnabled) {
      final key =
          'local-asl:${frames.first.timestamp.microsecondsSinceEpoch}:${word.toLowerCase()}';
      if (key != _lastSpokenAnalysisKey) {
        _lastSpokenAnalysisKey = key;
        unawaited(readCaptionAloud());
      }
    }
  }

  void _scheduleUtteranceAutoCommit() {
    // Pauses finish one isolated sign, not the full sentence. The signer
    // explicitly commits the accumulated words so the v1 backend receives
    // only completion_reason=user_commit and never incurs a call per word.
    _cancelUtteranceAutoCommit();
  }

  void _cancelUtteranceAutoCommit() {
    _utteranceIdleTimer?.cancel();
    _utteranceIdleTimer = null;
  }

  /// Gives a confidently matched personal sign precedence over the general
  /// ASL model. Private vocabulary stays on-device and does not modify the
  /// pretrained ONNX model.
  AslRecognitionResult _preferPersonalSign(
    AslRecognitionResult modelResult,
    List<LandmarkFrame> frames,
  ) => _personalSignRecognition(frames) ?? modelResult;

  AslRecognitionResult? _personalSignRecognition(List<LandmarkFrame> frames) {
    final sequence = _featureSequence(frames);
    final match = _personalSignMatcher.match(
      sequence: sequence,
      signs: customSigns,
      language: selectedLanguage,
    );
    if (match == null) return null;
    return AslRecognitionResult(
      status: 'recognized',
      word: match.label,
      confidence: match.confidence,
      modelVersion: 'personal_landmark_templates_v1',
      frameCount: sequence.length,
      detail:
          'Matched ${match.sampleCount} personal landmark recordings locally',
      alternatives: <AslRecognitionCandidate>[
        AslRecognitionCandidate(
          word: match.label,
          confidence: match.confidence,
          rank: 1,
        ),
      ],
      startedAtMs: frames.first.timestamp.millisecondsSinceEpoch,
      endedAtMs: frames.last.timestamp.millisecondsSinceEpoch,
    );
  }

  SignAnalysisResult _localAslAnalysis(AslRecognitionResult result) {
    final hypotheses = result.alternatives
        .map(
          (candidate) => <String, dynamic>{
            'word': candidate.word,
            'confidence': candidate.confidence,
            'rank': candidate.rank,
          },
        )
        .toList(growable: false);
    final latency = <String, dynamic>{
      if (result.inferenceMs != null) 'local_inference': result.inferenceMs,
      if (result.inferenceMs != null) 'total': result.inferenceMs,
    };
    if (result.isRecognized) {
      final word = result.word!;
      return SignAnalysisResult(
        status: 'confident',
        gestureLabel: word,
        caption: word,
        ttsText: word,
        confidence: result.confidence,
        glossTrace: <String>[word.toUpperCase()],
        hypotheses: hypotheses,
        modelVersion: result.modelVersion,
        latencyMs: latency,
        detail:
            result.detail ??
            '${result.frameCount} MediaPipe landmark frames · Signchat ONNX browser inference',
      );
    }
    return SignAnalysisResult(
      status: result.status == 'unavailable' ? 'unknown' : result.status,
      gestureLabel: 'Unknown ASL sign',
      caption: result.status == 'unavailable'
          ? 'Local ASL model unavailable.'
          : result.alternatives.isEmpty
          ? 'No ASL sign detected.'
          : 'Possible sign: ${result.alternatives.first.word} '
                '(${(result.alternatives.first.confidence * 100).round()}%)',
      confidence: result.confidence,
      glossTrace: const <String>[],
      hypotheses: hypotheses,
      modelVersion: result.modelVersion,
      latencyMs: latency,
      detail: result.detail ?? result.reason ?? '',
      reasonCodes: result.reason == null
          ? const <String>[]
          : <String>[result.reason!],
    );
  }

  /// Submits exactly one completed utterance. If its acknowledgement is lost,
  /// the retained immutable payload is sent again with the same UUID and
  /// sequence number; a new utterance is never created for that retry.
  Future<void> commitTranslatedUtterance({
    TranslatedSignUtteranceCompletionReason completionReason =
        TranslatedSignUtteranceCompletionReason.userCommit,
  }) async {
    if (_utteranceSubmissionInFlight) return;
    if (!_utteranceSubmission.isConfigured) {
      backendStatus =
          _utteranceSubmission.configurationMessage ??
          'Room submission is not configured.';
      notifyListeners();
      return;
    }
    if (_pendingUtterance == null && _utteranceWords.isEmpty) {
      backendStatus = 'Sign at least one word before translating an utterance';
      notifyListeners();
      return;
    }

    TranslatedSignUtterance utterance;
    try {
      utterance = _pendingUtterance ?? _buildFinalUtterance(completionReason);
    } on Object catch (error) {
      backendStatus =
          'Could not prepare final utterance · ${_shortError(error)}';
      notifyListeners();
      return;
    }

    _pendingUtterance = utterance;
    _cancelUtteranceAutoCommit();
    _utteranceSubmissionInFlight = true;
    backendStatus =
        'Submitting final ${utterance.words.length}-word utterance…';
    notifyListeners();
    try {
      final acknowledgement = await _utteranceSubmission.submit(utterance);
      if (_disposed) return;
      _pendingUtterance = null;
      _utteranceWords.clear();
      _draftMessageId = null;
      backendStatus = acknowledgement.wasCached
          ? 'Utterance replay accepted · waiting for the room result'
          : 'Utterance accepted · waiting for the room result';
    } on TranslatedSignUtteranceSubmissionException catch (error) {
      if (_disposed) return;
      backendStatus = error.retryable
          ? '${error.message} Tap Translate to retry the same utterance.'
          : error.message;
    } on Object catch (error) {
      if (_disposed) return;
      backendStatus =
          'Could not submit the final utterance · ${_shortError(error)}';
    } finally {
      _utteranceSubmissionInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  TranslatedSignUtterance _buildFinalUtterance(
    TranslatedSignUtteranceCompletionReason completionReason,
  ) {
    final producer = _utteranceWords.first.producer;
    if (_utteranceWords.any((word) => word.producer != producer)) {
      throw StateError(
        'One utterance cannot mix recognizer profiles. Translate the current words before switching recognizers.',
      );
    }
    return TranslatedSignUtterance(
      messageId: _draftMessageId ??= _messageIdGenerator(),
      clientSequence: _utteranceSubmission.nextClientSequence,
      completionReason: completionReason,
      producer: producer,
      words: <TranslatedSignWordToken>[
        for (var index = 0; index < _utteranceWords.length; index += 1)
          TranslatedSignWordToken(
            index: index,
            tokenId: 'word-$index',
            word: _utteranceWords[index].word,
            confidence: _utteranceWords[index].confidence,
            alternatives: <TranslatedSignWordAlternative>[
              for (
                var alternativeIndex = 0;
                alternativeIndex < _utteranceWords[index].alternatives.length;
                alternativeIndex += 1
              )
                TranslatedSignWordAlternative(
                  rank: alternativeIndex + 2,
                  word: _utteranceWords[index]
                      .alternatives[alternativeIndex]
                      .word,
                  confidence: _utteranceWords[index]
                      .alternatives[alternativeIndex]
                      .confidence,
                ),
            ],
          ),
      ],
    );
  }

  TranslatedSignUtteranceProducer _producerFor(AslRecognitionResult result) {
    final isPersonalTemplate = result.modelVersion.startsWith(
      'personal_landmark_templates',
    );
    return TranslatedSignUtteranceProducer(
      recognizerId: isPersonalTemplate
          ? 'personal_landmark_templates'
          : 'signchat_asl_signs_onnx',
      recognizerVersion: result.modelVersion,
      translatorId: 'asl_label_to_english',
      translatorVersion: '1.0.0',
      vocabularyVersion: isPersonalTemplate
          ? 'personal_signs_local_v1'
          : 'popsign_250_en_v1',
      confidenceKind:
          TranslatedSignUtteranceConfidenceKind.normalizedModelScore,
    );
  }

  Future<void> completeCalibrationStep() async {
    if (calibrationStep < 3) {
      calibrationStep += 1;
      notifyListeners();
      return;
    }
    calibrated = true;
    await _localState.setCalibrated(true);
    page = SignBridgePage.live;
    notifyListeners();
  }

  Future<void> recalibrate() async {
    calibrated = false;
    calibrationStep = 1;
    page = SignBridgePage.onboarding;
    await _localState.setCalibrated(false);
    notifyListeners();
  }

  void setViewMode(ViewMode mode) {
    viewMode = mode;
    notifyListeners();
  }

  void toggleAudio() {
    audioEnabled = !audioEnabled;
    notifyListeners();
  }

  void togglePause() {
    isPaused = !isPaused;
    if (isPaused) {
      _cancelUtteranceAutoCommit();
      _recognitionGeneration += 1;
      _signBoundaryDetector.reset();
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      unawaited(_aslRecognizer.reset());
    } else {
      _scheduleUtteranceAutoCommit();
    }
    notifyListeners();
  }

  /// Suspends automatic word recognition only while a personal template is
  /// being recorded. Camera tracking continues so the template can be built
  /// from the live MediaPipe landmark stream.
  void setPersonalSignRecording(bool value) {
    if (_teachingPersonalSign == value) return;
    _teachingPersonalSign = value;
    if (value) {
      _cancelUtteranceAutoCommit();
      _recognitionGeneration += 1;
      _signBoundaryDetector.reset();
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      unawaited(_aslRecognizer.reset());
    } else {
      _scheduleUtteranceAutoCommit();
    }
    notifyListeners();
  }

  void clearCaption() {
    if (_pendingUtterance != null) {
      backendStatus =
          'A final utterance is awaiting retry and cannot be changed';
      notifyListeners();
      return;
    }
    isUnregisteredSign = false;
    _cancelUtteranceAutoCommit();
    _utteranceWords.clear();
    _draftMessageId = null;
    latestAnalysis = null;
    backendStatus = 'Local word buffer cleared';
    notifyListeners();
  }

  void setUnregisteredSign(bool value) {
    isUnregisteredSign = value;
    notifyListeners();
  }

  Future<void> saveCustomSign(
    String label,
    List<List<List<double>>> sequences,
  ) async {
    final frame = latestFrame;
    final samples = sequences
        .where((sequence) => sequence.isNotEmpty)
        .map(
          (sequence) =>
              List<double>.unmodifiable(sequence[sequence.length ~/ 2]),
        )
        .toList(growable: false);
    final sign = CustomSign(
      label: label,
      samples: samples,
      sequences: sequences,
      createdAt: DateTime.now(),
      language: selectedLanguage,
      vectorSize: samples.isEmpty ? 0 : samples.first.length,
      coordinateSpace: _coordinateSpace(frame),
      faceSignal: frame?.faceExpression?.label ?? 'not captured',
    );
    customSigns = <CustomSign>[...customSigns, sign];
    await _localState.saveCustomSigns(customSigns);
    notifyListeners();
  }

  /// Builds one fixed-width sample for personal-sign matching.
  ///
  /// The live API keeps every raw landmark. My Signs additionally stores the
  /// fixed-width local sample: wrist-centred left/right hands, a
  /// shoulder-centred pose subset, curated face geometry, and facial-
  /// expression scores. The network contract remains LandmarkFrame JSON.
  List<double>? captureCurrentSignSample() =>
      _featureVectorForFrame(latestFrame);

  /// Returns the valid frames captured after [startedAt]. A personal-template
  /// recording needs a short sequence, rather than a single pose snapshot.
  List<List<double>>? capturePersonalSignSequence(DateTime startedAt) {
    final sequence = _featureSequence(
      tracking.recentFrames.where(
        (frame) => !frame.timestamp.isBefore(startedAt),
      ),
    );
    return sequence.length >= 8 ? sequence : null;
  }

  List<List<double>> _featureSequence(Iterable<LandmarkFrame> frames) => frames
      .where(
        (frame) => frame.trackingConfidence >= .70 && frame.hands.isNotEmpty,
      )
      .map(_featureVectorForFrame)
      .whereType<List<double>>()
      .toList(growable: false);

  List<double>? _featureVectorForFrame(LandmarkFrame? frame) {
    if (frame == null ||
        frame.trackingConfidence < .70 ||
        frame.hands.isEmpty) {
      return null;
    }

    // Frames produced by HandPoseNormalizer already contain the same fixed
    // four-world vector that the backend receives.
    if (frame.featureVector.isNotEmpty) {
      return List<double>.unmodifiable(frame.featureVector);
    }

    final vector = <double>[];
    for (final handedness in <Handedness>[Handedness.left, Handedness.right]) {
      TrackedHand? hand;
      for (final candidate in frame.hands) {
        if (candidate.handedness == handedness) {
          hand = candidate;
          break;
        }
      }
      if (hand == null || hand.landmarks.length < 21) {
        vector.addAll(List<double>.filled(63, 0));
        continue;
      }
      final wrist = hand.landmarks.first;
      final span = _handSpan(hand);
      for (final landmark in hand.landmarks) {
        vector.addAll(<double>[
          (landmark.x - wrist.x) / span,
          (landmark.y - wrist.y) / span,
          (landmark.z - wrist.z) / span,
        ]);
      }
    }

    final face = frame.faceExpression;
    for (final emotion in deepFaceEmotionLabels) {
      vector.add(face?.emotionScores[emotion] ?? 0);
    }
    return vector;
  }

  Future<void> deleteCustomSign(CustomSign sign) async {
    customSigns = customSigns.where((item) => item != sign).toList();
    await _localState.saveCustomSigns(customSigns);
    notifyListeners();
  }

  String _coordinateSpace(LandmarkFrame? frame) {
    if (frame == null || frame.handCoordinateAnalysis.isEmpty) {
      return 'normalized_3d';
    }
    final hasWorld = frame.handCoordinateAnalysis.any(
      (analysis) => analysis.coordinateSpace == 'world_wrist_centered',
    );
    return hasWorld
        ? 'world_3d_wrist_centered'
        : 'image_normalized_wrist_centered';
  }

  double _handSpan(TrackedHand hand) {
    final wrist = hand.landmarks.first;
    final middleMcp = hand.landmarks[9];
    final indexMcp = hand.landmarks[5];
    final pinkyMcp = hand.landmarks[17];
    final span =
        ((middleMcp.x - wrist.x).abs() +
            (middleMcp.y - wrist.y).abs() +
            (indexMcp.x - pinkyMcp.x).abs()) /
        3;
    return span.clamp(.08, 1.0);
  }

  @override
  void dispose() {
    _disposed = true;
    _recognitionGeneration += 1;
    final integration = _serverLandmarkStream;
    _serverLandmarkStream = null;
    unawaited(integration?.close());
    _frameNotifyTimer?.cancel();
    _cancelUtteranceAutoCommit();
    unawaited(_aslRecognizer.reset());
    _aslRecognizer.dispose();
    _trackingSubscription.cancel();
    WidgetsBinding.instance.removeObserver(this);
    speechToText.removeListener(_onSpeechToTextChanged);
    speechToText.dispose();
    unawaited(textToSpeech.dispose());
    tracking.dispose();
    devices.dispose();
    super.dispose();
  }

  String _shortError(Object error) {
    final text = error.toString();
    return text.length <= 160 ? text : '${text.substring(0, 157)}...';
  }
}

final class _BufferedTranslatedWord {
  _BufferedTranslatedWord({
    required this.word,
    required this.confidence,
    required this.producer,
    required List<EnglishLabelAlternative> alternatives,
  }) : alternatives = List<EnglishLabelAlternative>.unmodifiable(alternatives);

  final String word;
  final double confidence;
  final TranslatedSignUtteranceProducer producer;
  final List<EnglishLabelAlternative> alternatives;
}

String _newUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
