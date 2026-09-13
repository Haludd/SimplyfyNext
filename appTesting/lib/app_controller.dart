import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'config/landmark_stream_client_config.dart';
import 'models/asl_recognition_models.dart';
import 'contracts/landmark_stream.dart';
import 'models/face_tracking_models.dart';
import 'models/tracking_models.dart';
import 'models/hand_tracking_models.dart';
import 'models/speech_recognition_models.dart';
import 'services/device_access_service.dart';
import 'services/asl_recognizer_bridge.dart';
import 'services/asl_word_submission_service.dart';
import 'services/local_state_service.dart';
import 'services/local_sign_sequence.dart';
import 'services/sign_analysis_service.dart';
import 'services/speech_to_text_service.dart';
import 'services/text_to_speech_service.dart';
import 'services/tracking_service.dart';
import 'services/sign_boundary_detector.dart';
import 'services/gloss_lattice_websocket_client.dart';
import 'services/server_landmark_stream_integration.dart';

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
    AslWordSubmissionService? wordSubmission,
  }) : speechToText = speechToText ?? SpeechToTextService(),
       textToSpeech = textToSpeech ?? TextToSpeechService(),
       _aslRecognizer = aslRecognizer ?? AslRecognizerBridge(),
       _wordSubmission =
           wordSubmission ?? AslWordSubmissionService.fromEnvironment() {
    backendStatus = 'Local capture only · no backend request';
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
  final AslWordSubmissionService _wordSubmission;
  final SignAnalysisService signAnalyzer = SignAnalysisService();
  final SimulatedSignSequenceApiClient simulator =
      SimulatedSignSequenceApiClient();
  final SignBoundaryDetector _signBoundaryDetector = SignBoundaryDetector();
  final String sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';

  late final StreamSubscription<LandmarkFrame> _trackingSubscription;
  Timer? _frameNotifyTimer;
  SignBridgePage page = SignBridgePage.onboarding;
  ViewMode viewMode = ViewMode.wireframe;
  int calibrationStep = 1;
  bool calibrated = false;
  bool audioEnabled = true;
  bool isPaused = false;
  bool isUnregisteredSign = false;
  List<CustomSign> customSigns = <CustomSign>[];
  SignAnalysisResult? latestAnalysis;

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
  int _recognitionGeneration = 0;
  bool _disposed = false;
  bool _automaticFinishInFlight = false;
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
      unawaited(speechToText.stopListening());
      unawaited(textToSpeech.stop());
    }
  }

  void _onTrackingFrame(LandmarkFrame frame) {
    if (!_serverOwnsUtteranceLifecycle) {
      // In local mode signs are automatic. In server mode the Railway
      // segmenter owns this lifecycle and the client only streams frames.
      if (!analysisInFlight &&
          !_automaticFinishInFlight &&
          !tracking.isCapturingSign &&
          _hasCaptureSignal(frame)) {
        _signBoundaryDetector.reset();
        tracking.beginSign();
        if (_usesLocalAslModel) unawaited(_aslRecognizer.beginCapture());
        // Keep the completed word on screen while the next sign is being
        // captured. It will be replaced only by the next completed result.
        backendStatus = _usesLocalAslModel
            ? 'Listening · collecting one local sign'
            : 'Listening · capturing one sign automatically';
      }

      if (tracking.isCapturingSign && !_automaticFinishInFlight) {
        if (_signBoundaryDetector.update(frame)) {
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

  bool get _usesLocalAslModel =>
      !_serverOwnsUtteranceLifecycle &&
      selectedLanguage.trim().toUpperCase() == 'ASL' &&
      _aslRecognizer.isSupported;

  /// Whether the live ASL result can be corrected with a browser-local
  /// personal motion template. This does not upload the capture.
  bool get canTeachLastAslCapture =>
      _usesLocalAslModel &&
      !analysisInFlight &&
      latestAnalysis?.modelVersion != null;

  Future<AslPersonalTemplateReceipt?> teachLastAslCapture(String label) =>
      _aslRecognizer.teachLastCapture(label);

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

  /// Convenience handoff for the coordinator's terminal receipt.
  void acceptBackendReceipt(GlossLatticeSubmissionReceipt receipt) {
    acceptBackendEvent(receipt.terminalEvent);
  }

  /// Starts one sign capture. Normal UI capture starts automatically when a
  /// usable hand signal appears.
  void startSign() {
    if (_serverOwnsUtteranceLifecycle) {
      backendStatus = 'Backend captures signs automatically';
      notifyListeners();
      return;
    }
    if (analysisInFlight || tracking.isCapturingSign) return;
    if (latestFrame == null) {
      backendStatus = 'Start the camera before capturing a sign';
      notifyListeners();
      return;
    }
    _signBoundaryDetector.reset();
    tracking.beginSign();
    if (_usesLocalAslModel) unawaited(_aslRecognizer.beginCapture());
    // A manual capture should not make the previous sign disappear before
    // there is a newer completed result to show.
    backendStatus = _usesLocalAslModel
        ? 'Capturing one local sign'
        : 'Capturing one sign locally';
    notifyListeners();
  }

  /// Older callers can still start the same single-sign capture.
  @Deprecated('Use startSign')
  void startUtterance() => startSign();

  /// JSON-ready handoff for the next processing stage. The source of truth is
  /// still [lastSignFrames], not this serialized convenience view.
  List<Map<String, dynamic>> get lastSignJson => lastSignFrames
      .map((frame) => frame.toJson())
      .toList(growable: false);

  @Deprecated('Use lastSignJson')
  List<Map<String, dynamic>> get lastUtteranceJson => lastSignJson;

  void setLanguage(String language) {
    if (selectedLanguage != language) {
      _recognitionGeneration += 1;
      unawaited(_aslRecognizer.reset());
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      _signBoundaryDetector.reset();
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

  Future<void> analyzeSign({bool automatic = false}) async {
    if (_serverOwnsUtteranceLifecycle) {
      backendStatus = 'Backend is capturing and segmenting signs automatically';
      notifyListeners();
      return;
    }
    if (analysisInFlight || _automaticFinishInFlight) return;
    if (!tracking.isCapturingSign) {
      backendStatus = 'Waiting for a tracked hand signal';
      notifyListeners();
      return;
    }
    analysisInFlight = true;
    _automaticFinishInFlight = automatic;
    final generation = _recognitionGeneration;
    final useLocalModel = _usesLocalAslModel;
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
      if (useLocalModel) {
        final result = await _aslRecognizer.finishCapture();
        if (generation != _recognitionGeneration || _disposed) return;
        if (result == null) {
          throw StateError('Local ASL recognizer unavailable');
        }
        _acceptBrowserRecognition(result, frames);
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
      analysisInFlight = false;
      _automaticFinishInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _acceptBrowserRecognition(
    AslRecognitionResult result,
    List<LandmarkFrame> frames,
  ) {
    _setLatestAnalysis(_browserAnalysis(result));
    if (!result.isRecognized) {
      backendStatus = result.status == 'unavailable'
          ? 'Local ASL model unavailable · ${result.detail ?? 'install the ASL model assets'}'
          : switch (result.reason) {
              'too_few_hand_frames' || 'too_few_model_frames' =>
                'Keep your face and signing hand in view for the whole sign',
              'tracking_interrupted' => 'Tracking was interrupted · keep your face and hands in view and retry',
              'capture_too_long' => 'Sign one word, then pause briefly',
              _ => 'No high-confidence ASL word · sign again slowly',
            };
      return;
    }

    final word = result.word!;
    backendStatus = _wordSubmission.isConfigured
        ? 'Local ASL word recognized · sending "$word" to backend'
        : 'Local ASL word recognized · no word backend configured';
    if (audioEnabled) {
      final key =
          'local-asl:${frames.first.timestamp.microsecondsSinceEpoch}:${word.toLowerCase()}';
      if (key != _lastSpokenAnalysisKey) {
        _lastSpokenAnalysisKey = key;
        unawaited(readCaptionAloud());
      }
    }
    unawaited(_submitRecognizedWord(result, frames));
  }

  SignAnalysisResult _browserAnalysis(AslRecognitionResult result) {
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
            '${result.frameCount} local frames · browser TensorFlow Lite inference',
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

  Future<void> _submitRecognizedWord(
    AslRecognitionResult result,
    List<LandmarkFrame> frames,
  ) async {
    if (!_wordSubmission.isConfigured || !result.isRecognized) return;
    final generation = _recognitionGeneration;
    final submittedAnalysis = latestAnalysis;
    bool isCurrent() =>
        !_disposed &&
        generation == _recognitionGeneration &&
        identical(latestAnalysis, submittedAnalysis);
    try {
      final receipt = await _wordSubmission.submit(
        eventId: 'asl-${DateTime.now().microsecondsSinceEpoch}',
        sessionId: sessionId,
        language: selectedLanguage,
        result: result,
        startedAt: result.startedAtMs == null
            ? frames.first.timestamp
            : DateTime.fromMillisecondsSinceEpoch(
                result.startedAtMs!,
                isUtc: true,
              ),
        endedAt: result.endedAtMs == null
            ? frames.last.timestamp
            : DateTime.fromMillisecondsSinceEpoch(
                result.endedAtMs!,
                isUtc: true,
              ),
      );
      if (!isCurrent()) return;
      backendStatus = receipt == null
          ? 'Local ASL word recognized'
          : 'Word sent to backend · ${receipt.status}';
    } on Object catch (error) {
      if (!isCurrent()) return;
      backendStatus =
          'Local word recognized · backend submission failed · '
          '${_shortError(error)}';
    }
    notifyListeners();
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
    notifyListeners();
  }

  void clearCaption() {
    isUnregisteredSign = false;
    notifyListeners();
  }

  void setUnregisteredSign(bool value) {
    isUnregisteredSign = value;
    notifyListeners();
  }

  Future<void> saveCustomSign(String label, List<List<double>> samples) async {
    final frame = latestFrame;
    final sign = CustomSign(
      label: label,
      samples: samples,
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
  List<double>? captureCurrentSignSample() {
    final frame = latestFrame;
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
    unawaited(_aslRecognizer.reset());
    _aslRecognizer.dispose();
    _wordSubmission.close();
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
