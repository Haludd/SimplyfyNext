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

/// An optional local action that the signer maps to one of their recorded
/// personal signs. The chosen label never leaves this device.
enum PersonalSignShortcut {
  addPossibleWord('add_possible_word'),
  deleteLastWord('delete_last_word'),
  sendSentence('send_sentence');

  const PersonalSignShortcut(this.storageKey);
  final String storageKey;
}

/// The result of merging a user-controlled personal-sign backup into the
/// current device. A sign with the same label and language is replaced so a
/// newer recording can restore or improve an existing one.
class CustomSignBackupRestoreResult {
  const CustomSignBackupRestoreResult({
    required this.added,
    required this.replaced,
  });

  final int added;
  final int replaced;
  int get restored => added + replaced;
}

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  /// Keep automatic buffering aligned with the browser classifier and backend
  /// word policy. Results below this boundary remain available for review.
  static const double _manualReviewConfidenceThreshold = .40;

  AppController(
    this._localState,
    this.tracking,
    this.devices, {
    SpeechToTextService? speechToText,
    TextToSpeechService? textToSpeech,
    AslRecognizerBridge? aslRecognizer,
    TranslatedSignUtteranceGateway? utteranceSubmission,
    String Function()? messageIdGenerator,
  }) : speechToText = speechToText ?? SpeechToTextService(),
       textToSpeech = textToSpeech ?? TextToSpeechService(),
       _aslRecognizer = aslRecognizer ?? AslRecognizerBridge(),
       _utteranceSubmission =
           utteranceSubmission ??
           TranslatedSignUtteranceSubmissionService.fromEnvironment(),
       _messageIdGenerator = messageIdGenerator ?? _newUuidV4 {
    backendStatus =
        'Local recognition · words stay on this device until Send sentence';
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
  final SignAnalysisService signAnalyzer = SignAnalysisService();
  final SimulatedSignSequenceApiClient simulator =
      SimulatedSignSequenceApiClient();
  final SignBoundaryDetector _signBoundaryDetector = SignBoundaryDetector();
  final PersonalSignMatcher _personalSignMatcher = const PersonalSignMatcher();
  final AslLabelToEnglish _englishTranslator = const AslLabelToEnglish();
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

  /// Contract-safe English words held locally until the signer finishes the
  /// complete utterance. They are never sent one sign at a time.
  final List<_BufferedTranslatedWord> _utteranceWords =
      <_BufferedTranslatedWord>[];
  _PendingTranslatedWords? _pendingTranslatedWords;
  TranslatedSignUtterance? _pendingUtterance;
  String? _draftMessageId;
  String? _addPossibleWordShortcutLabel;
  String? _deleteLastWordShortcutLabel;
  String? _sendSentenceShortcutLabel;
  bool _utteranceSubmissionInFlight = false;

  List<String> get translatedWords =>
      List<String>.unmodifiable(_utteranceWords.map((word) => word.word));

  @Deprecated('Use translatedWords; v1 sends English words, not glosses.')
  List<String> get glosses => translatedWords;

  int get translatedWordCount => _utteranceWords.length;
  bool get hasTranslatedWords => _utteranceWords.isNotEmpty;
  bool get isUtteranceSubmissionConfigured => _utteranceSubmission.isConfigured;
  bool get isUtteranceSubmissionInFlight => _utteranceSubmissionInFlight;

  /// A submission whose HTTP acknowledgement has not arrived yet. The payload
  /// stays stable internally so a later manual send cannot create a duplicate.
  bool get hasPendingUtteranceSubmission => _pendingUtterance != null;
  bool get canCommitTranslatedUtterance =>
      !_utteranceSubmissionInFlight &&
      (_pendingUtterance != null || _utteranceWords.isNotEmpty);
  bool get canClearTranslatedUtterance =>
      _pendingUtterance == null && _utteranceWords.isNotEmpty;
  bool get hasPendingTranslatedWords => _pendingTranslatedWords != null;
  List<String> get pendingTranslatedWords => List<String>.unmodifiable(
    _pendingTranslatedWords?.words ?? const <String>[],
  );
  double? get pendingTranslatedWordConfidence =>
      _pendingTranslatedWords?.confidence;
  String? shortcutLabelFor(PersonalSignShortcut shortcut) => switch (shortcut) {
    PersonalSignShortcut.addPossibleWord => _addPossibleWordShortcutLabel,
    PersonalSignShortcut.deleteLastWord => _deleteLastWordShortcutLabel,
    PersonalSignShortcut.sendSentence => _sendSentenceShortcutLabel,
  };

  /// JSON that would be sent if the signer presses Send sentence now. It is safe
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
        backendStatus = 'The current sentence is still being sent. Send it before switching sign languages';
        notifyListeners();
        return;
      }
      _recognitionGeneration += 1;
      unawaited(_aslRecognizer.reset());
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      _signBoundaryDetector.reset();
      _utteranceWords.clear();
      _pendingTranslatedWords = null;
      _draftMessageId = null;
    }
    selectedLanguage = language;
    notifyListeners();
  }

  Future<void> _restoreState() async {
    calibrated = await _localState.isCalibrated();
    final savedSigns = await _localState.loadCustomSigns();
    customSigns = savedSigns;
    final savedShortcuts = await _localState.loadGestureShortcuts();
    _addPossibleWordShortcutLabel = _matchingCustomSignLabel(
      savedShortcuts[PersonalSignShortcut.addPossibleWord.storageKey],
    );
    _deleteLastWordShortcutLabel = _matchingCustomSignLabel(
      savedShortcuts[PersonalSignShortcut.deleteLastWord.storageKey],
    );
    _sendSentenceShortcutLabel = _matchingCustomSignLabel(
      savedShortcuts[PersonalSignShortcut.sendSentence.storageKey],
    );
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
        final personalMatch = _matchPersonalSign(frames);
        if (await _runPersonalSignShortcut(personalMatch, frames)) return;
        _dismissPendingForNextSign();
        _acceptLocalRecognition(
          _personalSignRecognition(personalMatch, frames) ?? result,
          frames,
        );
        return;
      }
      if (useLocalPersonalCapture) {
        final personalMatch = _matchPersonalSign(frames);
        if (await _runPersonalSignShortcut(personalMatch, frames)) return;
        _dismissPendingForNextSign();
        final result = _personalSignRecognition(personalMatch, frames);
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
    final reviewableResult = _reviewableLowConfidenceResult(result);
    if (!result.isRecognized && reviewableResult == null) {
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

    final acceptedResult = result.isRecognized ? result : reviewableResult!;
    final word = acceptedResult.word!;
    if (_pendingUtterance != null) {
      backendStatus = 'The current sentence is still being sent · wait for Send sentence to finish';
      return;
    }
    try {
      final translation = _englishTranslator.translate(acceptedResult);
      final producer = _producerFor(acceptedResult);
      final candidate = _PendingTranslatedWords(
        words: translation.words,
        confidence: acceptedResult.confidence,
        producer: producer,
        alternatives: translation.alternatives,
      );
      if (acceptedResult.confidence < _manualReviewConfidenceThreshold) {
        _pendingTranslatedWords = candidate;
        backendStatus =
            'Possible ${translation.words.join(' ')} '
            '(${(acceptedResult.confidence * 100).round()}%) · add it, ignore it, or make the next sign';
        return;
      }
      _appendTranslatedWords(candidate);
      backendStatus = _bufferedWordsStatus(translation.words);
    } on ArgumentError {
      backendStatus =
          'Recognized "$word" locally, but its English translation is unsupported';
      return;
    } on TranslatedSignUtteranceValidationException {
      backendStatus =
          'This sentence already has ${TranslatedSignUtteranceContract.maxWords} words · send it or remove a word before adding more';
      return;
    }
    // Each accepted word used to be spoken aloud immediately; that read a
    // single short word out of context and it was reported as a jarring
    // "thud" more often than as useful feedback. The caption card's own
    // brief green pulse (sign_screen.dart) now carries that "got it"
    // signal instead. Reading the finished sentence aloud is still
    // available on demand via the caption card's audio button.
  }

  void addPendingTranslatedWords() {
    final candidate = _pendingTranslatedWords;
    if (candidate == null || _pendingUtterance != null) return;
    try {
      _appendTranslatedWords(candidate);
      _pendingTranslatedWords = null;
      backendStatus = _bufferedWordsStatus(candidate.words);
    } on TranslatedSignUtteranceValidationException {
      backendStatus = 'That word cannot be added to this sentence. Remove a word or send the current sentence first.';
    }
    notifyListeners();
  }

  void discardPendingTranslatedWords() {
    final candidate = _pendingTranslatedWords;
    if (candidate == null || _pendingUtterance != null) return;
    _pendingTranslatedWords = null;
    backendStatus =
        'Skipped ${candidate.words.join(' ')} · ready for the next sign';
    notifyListeners();
  }

  /// Appends one of the currently visible recognition candidates by hand,
  /// translating its raw ASL label into contract-safe English word(s). This
  /// is how the signer picks a lower-ranked (or below-threshold) hypothesis
  /// instead of waiting for the top one to clear the confidence gate.
  void addHypothesisWord(String label, double confidence) {
    if (_pendingUtterance != null) {
      backendStatus =
          'The current sentence is still being sent · wait for Send sentence to finish';
      notifyListeners();
      return;
    }
    try {
      final words = _englishTranslator.translateLabel(label);
      // The pick already resolves this sign; an automatic pending review of
      // the same captured sign would otherwise still be waiting behind it.
      _pendingTranslatedWords = null;
      _appendTranslatedWords(
        _PendingTranslatedWords(
          words: words,
          confidence: confidence,
          producer: _producerForModel(
            latestAnalysis?.modelVersion ?? 'signchat_asl_signs_onnx',
          ),
          alternatives: const <EnglishLabelAlternative>[],
        ),
      );
      backendStatus = _bufferedWordsStatus(words);
    } on ArgumentError {
      backendStatus = 'That candidate has no supported English translation';
    } on TranslatedSignUtteranceValidationException {
      backendStatus =
          'This sentence already has ${TranslatedSignUtteranceContract.maxWords} words · send it or remove a word before adding more';
    }
    notifyListeners();
  }

  void _dismissPendingForNextSign() {
    if (_pendingTranslatedWords == null) return;
    _pendingTranslatedWords = null;
  }

  void removeTranslatedWordAt(int index) {
    if (_pendingUtterance != null ||
        index < 0 ||
        index >= _utteranceWords.length) {
      return;
    }
    final removed = _utteranceWords.removeAt(index);
    if (_utteranceWords.isEmpty) _draftMessageId = null;
    backendStatus =
        'Removed ${removed.word} · ${_utteranceWords.length} word${_utteranceWords.length == 1 ? '' : 's'} remain';
    notifyListeners();
  }

  void _appendTranslatedWords(_PendingTranslatedWords candidate) {
    if (_utteranceWords.length + candidate.words.length >
        TranslatedSignUtteranceContract.maxWords) {
      throw const TranslatedSignUtteranceValidationException(
        'An utterance may contain at most 64 words.',
      );
    }
    _draftMessageId ??= _messageIdGenerator();
    for (var index = 0; index < candidate.words.length; index += 1) {
      _utteranceWords.add(
        _BufferedTranslatedWord(
          word: candidate.words[index],
          confidence: candidate.confidence,
          producer: candidate.producer,
          alternatives: index == 0
              ? candidate.alternatives
              : const <EnglishLabelAlternative>[],
        ),
      );
    }
  }

  String _bufferedWordsStatus(List<String> words) =>
      _utteranceSubmission.isConfigured
      ? 'Added ${words.join(' ')} · ${_utteranceWords.length} '
            'word${_utteranceWords.length == 1 ? '' : 's'} ready · tap Send sentence when it is complete'
      : 'Added ${words.join(' ')} locally · '
            'configure a room to send the completed sentence';

  AslRecognitionResult? _reviewableLowConfidenceResult(
    AslRecognitionResult result,
  ) {
    final topCandidate = result.alternatives.isEmpty
        ? null
        : result.alternatives.first;
    if (result.status != 'unknown' ||
        result.reason != 'low_confidence' ||
        topCandidate == null) {
      return null;
    }
    return AslRecognitionResult(
      status: 'recognized',
      word: topCandidate.word,
      confidence: topCandidate.confidence,
      modelVersion: result.modelVersion,
      frameCount: result.frameCount,
      reason: result.reason,
      detail: result.detail,
      alternatives: result.alternatives,
      startedAtMs: result.startedAtMs,
      endedAtMs: result.endedAtMs,
      inferenceMs: result.inferenceMs,
    );
  }

  PersonalSignMatch? _matchPersonalSign(List<LandmarkFrame> frames) {
    final sequence = _featureSequence(frames);
    return _personalSignMatcher.match(
      sequence: sequence,
      signs: customSigns,
      language: selectedLanguage,
    );
  }

  /// Gives a confidently matched personal sign precedence over the general
  /// ASL model. Private vocabulary stays on-device and does not modify the
  /// pretrained ONNX model.
  AslRecognitionResult? _personalSignRecognition(
    PersonalSignMatch? match,
    List<LandmarkFrame> frames,
  ) {
    if (match == null) return null;
    return AslRecognitionResult(
      status: 'recognized',
      word: match.label,
      confidence: match.confidence,
      modelVersion: 'personal_landmark_templates_v1',
      frameCount: frames.length,
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

  Future<bool> _runPersonalSignShortcut(
    PersonalSignMatch? match,
    List<LandmarkFrame> frames,
  ) async {
    if (match == null) return false;
    final action = _shortcutForLabel(match.label);
    if (action == null) return false;

    final recognition = _personalSignRecognition(match, frames);
    if (recognition != null) _setLatestAnalysis(_localAslAnalysis(recognition));
    switch (action) {
      case PersonalSignShortcut.addPossibleWord:
        if (!hasPendingTranslatedWords) {
          backendStatus =
              'Gesture ${match.label} recognised · no possible word is waiting to add';
          notifyListeners();
          return true;
        }
        addPendingTranslatedWords();
        backendStatus = 'Gesture ${match.label} recognised · $backendStatus';
        notifyListeners();
        return true;
      case PersonalSignShortcut.deleteLastWord:
        _dismissPendingForNextSign();
        if (!hasTranslatedWords) {
          backendStatus =
              'Gesture ${match.label} recognised · no sentence word is available to remove';
          notifyListeners();
          return true;
        }
        removeTranslatedWordAt(translatedWordCount - 1);
        backendStatus = 'Gesture ${match.label} recognised · $backendStatus';
        notifyListeners();
        return true;
      case PersonalSignShortcut.sendSentence:
        _dismissPendingForNextSign();
        if (!hasTranslatedWords && !hasPendingUtteranceSubmission) {
          backendStatus =
              'Gesture ${match.label} recognised · add a word before sending a sentence';
          notifyListeners();
          return true;
        }
        backendStatus = 'Gesture ${match.label} recognised · sending sentence…';
        notifyListeners();
        await commitTranslatedUtterance();
        return true;
    }
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

  /// Submits exactly one completed utterance. If an acknowledgement is delayed,
  /// the retained immutable payload is used by the normal Send sentence action
  /// with the same UUID and sequence number, preventing a duplicate utterance.
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
      backendStatus =
          'Add at least one recognised word before sending a sentence';
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
          ? '${error.message} The sentence is kept safe; use Send sentence when the room is available.'
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
        'One sentence cannot mix recognizer profiles. Send the current words before switching recognizers.',
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

  TranslatedSignUtteranceProducer _producerFor(AslRecognitionResult result) =>
      _producerForModel(result.modelVersion);

  TranslatedSignUtteranceProducer _producerForModel(String modelVersion) {
    final isPersonalTemplate = modelVersion.startsWith(
      'personal_landmark_templates',
    );
    return TranslatedSignUtteranceProducer(
      recognizerId: isPersonalTemplate
          ? 'personal_landmark_templates'
          : 'signchat_asl_signs_onnx',
      recognizerVersion: modelVersion,
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
      _recognitionGeneration += 1;
      _signBoundaryDetector.reset();
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      unawaited(_aslRecognizer.reset());
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
      _recognitionGeneration += 1;
      _signBoundaryDetector.reset();
      if (tracking.isCapturingSign) unawaited(tracking.finishSign());
      unawaited(_aslRecognizer.reset());
    }
    notifyListeners();
  }

  void clearCaption() {
    if (_pendingUtterance != null) {
      backendStatus =
          'The current sentence is still being sent and cannot be changed yet';
      notifyListeners();
      return;
    }
    isUnregisteredSign = false;
    _utteranceWords.clear();
    _pendingTranslatedWords = null;
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
    final normalizedLabel = label.trim();
    final matchingSigns = customSigns
        .where(
          (sign) =>
              sign.language.toUpperCase() == selectedLanguage.toUpperCase() &&
              sign.label.trim().toLowerCase() == normalizedLabel.toLowerCase(),
        )
        .toList(growable: false);
    final combinedSequences = <List<List<double>>>[
      for (final sign in matchingSigns) ...sign.templateSequences,
      ...sequences.where((sequence) => sequence.isNotEmpty),
    ];
    // More examples improve recognition, but a bounded recent set keeps
    // matching responsive and avoids unbounded browser storage growth.
    const maximumExamples = 20;
    final retainedSequences = combinedSequences.length <= maximumExamples
        ? combinedSequences
        : combinedSequences.sublist(combinedSequences.length - maximumExamples);
    final samples = retainedSequences
        .map(
          (sequence) =>
              List<double>.unmodifiable(sequence[sequence.length ~/ 2]),
        )
        .toList(growable: false);
    final sign = CustomSign(
      label: normalizedLabel,
      samples: samples,
      sequences: retainedSequences,
      createdAt: matchingSigns.isEmpty
          ? DateTime.now()
          : matchingSigns
                .map((sign) => sign.createdAt)
                .reduce((first, next) => first.isBefore(next) ? first : next),
      language: selectedLanguage,
      vectorSize: samples.isEmpty ? 0 : samples.first.length,
      coordinateSpace: _coordinateSpace(frame),
      faceSignal: frame?.faceExpression?.label ?? 'not captured',
    );
    customSigns = <CustomSign>[
      ...customSigns.where((existing) => !matchingSigns.contains(existing)),
      sign,
    ];
    await _localState.saveCustomSigns(customSigns);
    backendStatus = matchingSigns.isEmpty
        ? '$normalizedLabel saved with ${sign.sampleCount} examples'
        : '$normalizedLabel improved with ${sign.sampleCount} examples';
    notifyListeners();
  }

  /// A portable JSON copy of the local-only personal-sign templates. It never
  /// appears in a room message or leaves the browser without an explicit user
  /// action such as copy/paste.
  String exportCustomSignsBackup() =>
      _localState.exportCustomSignsBackup(customSigns);

  Future<CustomSignBackupRestoreResult> restoreCustomSignsBackup(
    String encoded,
  ) async {
    final incoming = _localState.decodeCustomSignsBackup(encoded);
    final incomingByKey = <String, CustomSign>{
      for (final sign in incoming) _customSignBackupKey(sign): sign,
    };
    final existingKeys = customSigns.map(_customSignBackupKey).toSet();
    final replaced = incomingByKey.keys.where(existingKeys.contains).length;
    final added = incomingByKey.length - replaced;
    final merged = <CustomSign>[];
    for (final existing in customSigns) {
      final replacement = incomingByKey.remove(_customSignBackupKey(existing));
      merged.add(replacement ?? existing);
    }
    merged.addAll(incomingByKey.values);
    customSigns = merged;
    await _localState.saveCustomSigns(customSigns);
    notifyListeners();
    return CustomSignBackupRestoreResult(added: added, replaced: replaced);
  }

  String _customSignBackupKey(CustomSign sign) =>
      '${sign.language.trim().toUpperCase()}\u0000${sign.label.trim().toLowerCase()}';

  Future<void> setPersonalSignShortcut(
    PersonalSignShortcut shortcut,
    String? label,
  ) async {
    final requested = label?.trim();
    final matchingLabel = requested == null || requested.isEmpty
        ? null
        : _matchingCustomSignLabel(requested);
    if (requested != null && requested.isNotEmpty && matchingLabel == null) {
      backendStatus = 'Choose a saved personal sign for this gesture control';
      notifyListeners();
      return;
    }
    if (matchingLabel != null) _clearShortcutLabel(matchingLabel);
    switch (shortcut) {
      case PersonalSignShortcut.addPossibleWord:
        _addPossibleWordShortcutLabel = matchingLabel;
        break;
      case PersonalSignShortcut.deleteLastWord:
        _deleteLastWordShortcutLabel = matchingLabel;
        break;
      case PersonalSignShortcut.sendSentence:
        _sendSentenceShortcutLabel = matchingLabel;
        break;
    }
    await _savePersonalSignShortcuts();
    backendStatus = matchingLabel == null
        ? 'Gesture shortcut turned off'
        : 'Gesture $matchingLabel is ready on this device';
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
    final deletedLabel = sign.label.toLowerCase();
    if (_addPossibleWordShortcutLabel?.toLowerCase() == deletedLabel) {
      _addPossibleWordShortcutLabel = null;
    }
    if (_deleteLastWordShortcutLabel?.toLowerCase() == deletedLabel) {
      _deleteLastWordShortcutLabel = null;
    }
    if (_sendSentenceShortcutLabel?.toLowerCase() == deletedLabel) {
      _sendSentenceShortcutLabel = null;
    }
    await _savePersonalSignShortcuts();
    notifyListeners();
  }

  String? _matchingCustomSignLabel(String? label) {
    final wanted = label?.trim().toLowerCase();
    if (wanted == null || wanted.isEmpty) return null;
    for (final sign in customSigns) {
      if (sign.hasEnoughSamples && sign.label.trim().toLowerCase() == wanted) {
        return sign.label;
      }
    }
    return null;
  }

  PersonalSignShortcut? _shortcutForLabel(String label) {
    final value = label.trim().toLowerCase();
    if (value.isEmpty) return null;
    if (value == _addPossibleWordShortcutLabel?.toLowerCase()) {
      return PersonalSignShortcut.addPossibleWord;
    }
    if (value == _deleteLastWordShortcutLabel?.toLowerCase()) {
      return PersonalSignShortcut.deleteLastWord;
    }
    if (value == _sendSentenceShortcutLabel?.toLowerCase()) {
      return PersonalSignShortcut.sendSentence;
    }
    return null;
  }

  void _clearShortcutLabel(String label) {
    final value = label.toLowerCase();
    if (_addPossibleWordShortcutLabel?.toLowerCase() == value) {
      _addPossibleWordShortcutLabel = null;
    }
    if (_deleteLastWordShortcutLabel?.toLowerCase() == value) {
      _deleteLastWordShortcutLabel = null;
    }
    if (_sendSentenceShortcutLabel?.toLowerCase() == value) {
      _sendSentenceShortcutLabel = null;
    }
  }

  Future<void> _savePersonalSignShortcuts() {
    final shortcuts = <String, String>{};
    final addPossibleWord = _addPossibleWordShortcutLabel;
    final sendSentence = _sendSentenceShortcutLabel;
    if (addPossibleWord != null) {
      shortcuts[PersonalSignShortcut.addPossibleWord.storageKey] =
          addPossibleWord;
    }
    final deleteLastWord = _deleteLastWordShortcutLabel;
    if (deleteLastWord != null) {
      shortcuts[PersonalSignShortcut.deleteLastWord.storageKey] =
          deleteLastWord;
    }
    if (sendSentence != null) {
      shortcuts[PersonalSignShortcut.sendSentence.storageKey] = sendSentence;
    }
    return _localState.saveGestureShortcuts(shortcuts);
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

final class _PendingTranslatedWords {
  _PendingTranslatedWords({
    required List<String> words,
    required this.confidence,
    required this.producer,
    required List<EnglishLabelAlternative> alternatives,
  }) : words = List<String>.unmodifiable(words),
       alternatives = List<EnglishLabelAlternative>.unmodifiable(alternatives);

  final List<String> words;
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
