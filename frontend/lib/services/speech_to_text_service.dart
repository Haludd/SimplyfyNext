import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/speech_recognition_models.dart';
import 'speech_recognizer_adapter.dart';

class SpeechToTextService extends ChangeNotifier {
  SpeechToTextService({SpeechRecognizerAdapter? adapter})
    : _adapter = adapter ?? SpeechToTextRecognizerAdapter();

  final SpeechRecognizerAdapter _adapter;

  SpeechServiceStatus _status = SpeechServiceStatus.uninitialized;
  bool _isAvailable = false;
  bool _isInitialized = false;
  bool _wantsToListen = false;
  bool _acceptPartialResults = false;
  bool _hasActiveListenRequest = false;
  bool _isDisposed = false;
  String _partialTranscript = '';
  String _finalTranscript = '';
  String? _lastFinalFingerprint;
  double? _confidence;
  SpeechLocale? _locale;
  List<SpeechLocale> _availableLocales = const <SpeechLocale>[];
  SpeechRecognitionErrorInfo? _lastError;
  String? _platformStatus;
  Future<bool>? _initialization;
  Future<void> _operationTail = Future<void>.value();
  Future<void> _lastOperation = Future<void>.value();
  int _intentRevision = 0;
  int _platformListenRevision = 0;
  int _activeSession = 0;

  SpeechServiceStatus get status => _status;
  bool get isAvailable => _isAvailable;
  bool get isInitialized => _isInitialized;
  bool get isListening => _status == SpeechServiceStatus.listening;
  String get partialTranscript => _partialTranscript;
  String get finalTranscript => _finalTranscript;
  String get transcript =>
      _finalTranscript.isNotEmpty ? _finalTranscript : _partialTranscript;
  double? get confidence => _confidence;
  SpeechLocale? get locale => _locale;
  List<SpeechLocale> get availableLocales => _availableLocales;
  SpeechRecognitionErrorInfo? get lastError => _lastError;
  String? get platformStatus => _platformStatus;

  Future<bool> initialize() {
    _ensureNotDisposed();
    if (_isInitialized && _isAvailable) return Future<bool>.value(true);
    final pending = _initialization;
    if (pending != null) return pending;

    final operation = _initialize();
    _initialization = operation;
    operation.whenComplete(() {
      if (identical(_initialization, operation)) _initialization = null;
    });
    return operation;
  }

  Future<bool> _initialize() async {
    _status = SpeechServiceStatus.initializing;
    _lastError = null;
    _notifyListeners();

    try {
      final available = await _adapter.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
      );
      if (_isDisposed) return false;
      if (_lastError?.isPermanent == true) {
        _isAvailable = false;
        _isInitialized = false;
        return false;
      }

      _isAvailable = available;
      _isInitialized = available;
      if (!available) {
        _status = SpeechServiceStatus.unavailable;
        _notifyListeners();
        return false;
      }

      await _loadLocales();
      if (_isDisposed) return false;
      _status = SpeechServiceStatus.ready;
      _notifyListeners();
      return true;
    } catch (error) {
      if (_isDisposed) return false;
      _isAvailable = false;
      _isInitialized = false;
      _recordError(error.toString(), isPermanent: false);
      return false;
    }
  }

  Future<void> _loadLocales() async {
    try {
      final locales = await _adapter.locales();
      final systemLocale = await _adapter.systemLocale();
      if (_isDisposed) return;

      final reconciledLocales = <SpeechLocale>[...locales];
      void addIfMissing(SpeechLocale? candidate) {
        if (candidate == null ||
            reconciledLocales.any(
              (locale) => locale.localeId == candidate.localeId,
            )) {
          return;
        }
        reconciledLocales.insert(0, candidate);
      }

      addIfMissing(systemLocale);
      addIfMissing(_locale);
      _availableLocales = List<SpeechLocale>.unmodifiable(reconciledLocales);
      if (_locale != null) {
        _locale = _findLocale(_locale!.localeId) ?? _locale;
      } else {
        _locale =
            systemLocale ??
            (reconciledLocales.isEmpty ? null : reconciledLocales.first);
      }
    } catch (_) {
      // Recognition can still work with the platform's default locale.
      if (!_isDisposed) _availableLocales = const <SpeechLocale>[];
    }
  }

  Future<void> startListening({
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  }) {
    _ensureNotDisposed();
    if (_wantsToListen) return _lastOperation;

    _wantsToListen = true;
    _acceptPartialResults = true;
    final intentRevision = ++_intentRevision;
    final session = ++_activeSession;
    _resetTranscript();
    _lastError = null;
    _status = SpeechServiceStatus.starting;
    if (localeId != null) _selectLocaleWithoutNotification(localeId);
    _notifyListeners();

    return _enqueue(() async {
      if (_isDisposed) return;
      final available = await initialize();
      if (_isDisposed || intentRevision != _intentRevision || !_wantsToListen) {
        return;
      }
      if (!available) {
        _wantsToListen = false;
        _acceptPartialResults = false;
        return;
      }

      _status = SpeechServiceStatus.starting;
      _notifyListeners();
      try {
        _hasActiveListenRequest = true;
        _platformListenRevision = intentRevision;
        await _adapter.listen(
          onResult: (result) => _handleResult(session, result),
          localeId: localeId ?? _locale?.localeId,
          listenFor: listenFor,
          pauseFor: pauseFor,
        );
      } catch (error) {
        if (_isDisposed || session != _activeSession) return;
        _hasActiveListenRequest = false;
        _wantsToListen = false;
        _acceptPartialResults = false;
        _recordError(error.toString(), isPermanent: false);
        return;
      }

      if (_isDisposed ||
          session != _activeSession ||
          intentRevision != _intentRevision ||
          !_wantsToListen) {
        return;
      }
      _status = SpeechServiceStatus.listening;
      _notifyListeners();
    });
  }

  Future<void> stopListening() {
    _ensureNotDisposed();
    if (_status == SpeechServiceStatus.stopping) return _lastOperation;
    if (!_wantsToListen &&
        _status != SpeechServiceStatus.starting &&
        _status != SpeechServiceStatus.listening &&
        _status != SpeechServiceStatus.stopping) {
      return _lastOperation;
    }

    _wantsToListen = false;
    final stopRevision = ++_intentRevision;
    _status = SpeechServiceStatus.stopping;
    _notifyListeners();

    return _enqueue(() async {
      if (_isDisposed) return;
      try {
        if (_hasActiveListenRequest || _adapter.isListening) {
          await _adapter.stop();
        }
      } catch (error) {
        if (!_isDisposed) {
          _recordError(error.toString(), isPermanent: false);
        }
        return;
      }

      if (_isDisposed) return;
      _hasActiveListenRequest = false;
      if (stopRevision != _intentRevision || _wantsToListen) return;
      _acceptPartialResults = false;
      if (_status != SpeechServiceStatus.error &&
          _status != SpeechServiceStatus.unavailable) {
        _status = _isAvailable
            ? SpeechServiceStatus.ready
            : SpeechServiceStatus.uninitialized;
      }
      _notifyListeners();
    });
  }

  Future<void> cancelListening() {
    _ensureNotDisposed();
    _wantsToListen = false;
    _acceptPartialResults = false;
    final cancelRevision = ++_intentRevision;
    _activeSession++;
    _resetTranscript();
    _status = _isAvailable
        ? SpeechServiceStatus.stopping
        : SpeechServiceStatus.uninitialized;
    _notifyListeners();

    return _enqueue(() async {
      if (_isDisposed) return;
      try {
        await _adapter.cancel();
      } catch (error) {
        if (!_isDisposed) {
          _recordError(error.toString(), isPermanent: false);
        }
        return;
      }

      if (_isDisposed) return;
      _hasActiveListenRequest = false;
      if (cancelRevision != _intentRevision || _wantsToListen) return;
      _status = _isAvailable
          ? SpeechServiceStatus.ready
          : SpeechServiceStatus.uninitialized;
      _notifyListeners();
    });
  }

  bool selectLocale(String localeId) {
    _ensureNotDisposed();
    final selected = _findLocale(localeId);
    if (selected == null || selected == _locale) return selected != null;
    _locale = selected;
    _notifyListeners();
    return true;
  }

  void clearTranscript() {
    _ensureNotDisposed();
    if (_partialTranscript.isEmpty &&
        _finalTranscript.isEmpty &&
        _confidence == null) {
      return;
    }
    _resetTranscript();
    _notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _lastOperation = result;
    return result;
  }

  void _handleResult(int session, SpeechRecognitionUpdate result) {
    if (_isDisposed || session != _activeSession) return;
    if (!result.isFinal && !_acceptPartialResults) return;
    if (!result.isFinal && _lastFinalFingerprint != null) return;

    final words = _cleanTranscript(result.transcript);
    if (words.isEmpty) {
      if (!result.isFinal && _partialTranscript.isNotEmpty) {
        _partialTranscript = '';
        _confidence = result.confidence;
        _notifyListeners();
      }
      return;
    }

    final oldConfidence = _confidence;
    _confidence = result.confidence;
    if (result.isFinal) {
      final fingerprint = words.toLowerCase();
      _partialTranscript = '';
      if (fingerprint == _lastFinalFingerprint) {
        if (_confidence != oldConfidence) _notifyListeners();
        return;
      }
      _lastFinalFingerprint = fingerprint;
      _finalTranscript = words;
    } else {
      if (_partialTranscript == words && _confidence == oldConfidence) return;
      _partialTranscript = words;
    }
    _notifyListeners();
  }

  void _handleStatus(String status) {
    if (_isDisposed) return;
    _platformStatus = status;
    if (_platformListenRevision != _intentRevision) {
      _notifyListeners();
      return;
    }
    switch (status.toLowerCase()) {
      case 'listening':
        if (_wantsToListen) _status = SpeechServiceStatus.listening;
        break;
      case 'done':
      case 'notlistening':
        if (_status == SpeechServiceStatus.initializing) break;
        if (_wantsToListen &&
            (!_hasActiveListenRequest || _adapter.isListening)) {
          break;
        }
        _wantsToListen = false;
        _acceptPartialResults = false;
        _hasActiveListenRequest = false;
        if (_isAvailable) _status = SpeechServiceStatus.ready;
        break;
    }
    _notifyListeners();
  }

  void _handleError(SpeechRecognitionErrorInfo error) {
    if (_isDisposed) return;
    if (!error.isPermanent &&
        _status != SpeechServiceStatus.initializing &&
        _platformListenRevision != _intentRevision) {
      return;
    }
    _applyError(error);
  }

  void _applyError(SpeechRecognitionErrorInfo error) {
    final shouldCancel = _hasActiveListenRequest || _adapter.isListening;
    _intentRevision++;
    _activeSession++;
    _lastError = error;
    _status = SpeechServiceStatus.error;
    _wantsToListen = false;
    _acceptPartialResults = false;
    _hasActiveListenRequest = false;
    if (error.isPermanent) _isAvailable = false;
    _notifyListeners();
    if (shouldCancel) {
      unawaited(
        _enqueue(() async {
          if (_isDisposed) return;
          try {
            await _adapter.cancel();
          } catch (_) {
            // Keep the recognition error that caused cancellation as the
            // actionable error exposed to the UI.
          }
        }),
      );
    }
  }

  void _recordError(String message, {required bool isPermanent}) {
    _applyError(
      SpeechRecognitionErrorInfo(message: message, isPermanent: isPermanent),
    );
  }

  SpeechLocale? _findLocale(String localeId) {
    for (final locale in _availableLocales) {
      if (locale.localeId == localeId) return locale;
    }
    return null;
  }

  void _selectLocaleWithoutNotification(String localeId) {
    _locale =
        _findLocale(localeId) ??
        SpeechLocale(localeId: localeId, name: localeId);
  }

  void _resetTranscript() {
    _partialTranscript = '';
    _finalTranscript = '';
    _lastFinalFingerprint = null;
    _confidence = null;
  }

  static String _cleanTranscript(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('SpeechToTextService has been disposed.');
    }
  }

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  Future<void> _disposeAdapter() async {
    try {
      await _adapter.dispose();
    } catch (_) {
      // Disposal is best effort. There is no mounted UI left to recover into,
      // and platform-channel teardown failures must not escape as async errors.
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _wantsToListen = false;
    _acceptPartialResults = false;
    _hasActiveListenRequest = false;
    _intentRevision++;
    _activeSession++;
    unawaited(_disposeAdapter());
    super.dispose();
  }
}
