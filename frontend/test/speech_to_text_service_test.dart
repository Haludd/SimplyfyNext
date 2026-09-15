import 'dart:async';

import 'package:apptesting/models/speech_recognition_models.dart';
import 'package:apptesting/services/speech_recognizer_adapter.dart';
import 'package:apptesting/services/speech_to_text_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpeechToTextService', () {
    late FakeSpeechRecognizerAdapter adapter;
    late SpeechToTextService service;

    setUp(() {
      adapter = FakeSpeechRecognizerAdapter();
      service = SpeechToTextService(adapter: adapter);
    });

    tearDown(() {
      service.dispose();
    });

    test('initializes availability and the system locale once', () async {
      adapter.availableLocales = const <SpeechLocale>[
        SpeechLocale(localeId: 'en_US', name: 'English'),
        SpeechLocale(localeId: 'id_ID', name: 'Bahasa Indonesia'),
      ];
      adapter.currentSystemLocale = adapter.availableLocales.last;

      expect(await service.initialize(), isTrue);
      expect(await service.initialize(), isTrue);

      expect(adapter.initializeCalls, 1);
      expect(service.isInitialized, isTrue);
      expect(service.isAvailable, isTrue);
      expect(service.status, SpeechServiceStatus.ready);
      expect(service.availableLocales, adapter.availableLocales);
      expect(service.locale, adapter.currentSystemLocale);
    });

    test('reports unavailable and does not start recognition', () async {
      adapter.initializeResult = false;

      await service.startListening();

      expect(service.isAvailable, isFalse);
      expect(service.isListening, isFalse);
      expect(service.status, SpeechServiceStatus.unavailable);
      expect(adapter.listenCalls, 0);
    });

    test(
      'adds a missing system locale to the selectable locale list',
      () async {
        adapter.availableLocales = const <SpeechLocale>[
          SpeechLocale(localeId: 'en_US', name: 'English'),
        ];
        adapter.currentSystemLocale = const SpeechLocale(
          localeId: 'id_ID',
          name: 'Bahasa Indonesia',
        );

        expect(await service.initialize(), isTrue);

        expect(service.locale, adapter.currentSystemLocale);
        expect(service.availableLocales, contains(adapter.currentSystemLocale));
      },
    );

    test(
      'retries initialization after unavailable and permanent errors',
      () async {
        adapter.initializeResult = false;
        expect(await service.initialize(), isFalse);
        expect(service.status, SpeechServiceStatus.unavailable);

        adapter.initializeResult = true;
        expect(await service.initialize(), isTrue);
        expect(adapter.initializeCalls, 2);

        adapter.emitError(
          const SpeechRecognitionErrorInfo(
            message: 'error_permission',
            isPermanent: true,
          ),
        );
        expect(service.isAvailable, isFalse);

        expect(await service.initialize(), isTrue);
        expect(adapter.initializeCalls, 3);
        expect(service.status, SpeechServiceStatus.ready);
      },
    );

    test('does not get stuck when adapter operations throw', () async {
      adapter.initializeError = StateError('init failed');

      expect(await service.initialize(), isFalse);
      expect(service.status, SpeechServiceStatus.error);
      expect(service.lastError?.message, contains('init failed'));

      adapter.initializeError = null;
      await service.startListening();
      adapter.stopError = StateError('stop failed');
      await service.stopListening();

      expect(service.status, SpeechServiceStatus.error);
      expect(service.lastError?.message, contains('stop failed'));
    });

    test('coalesces repeated starts for the same push-to-talk turn', () async {
      final first = service.startListening();
      final second = service.startListening();

      await Future.wait(<Future<void>>[first, second]);

      expect(adapter.initializeCalls, 1);
      expect(adapter.listenCalls, 1);
      expect(service.status, SpeechServiceStatus.listening);
    });

    test('release during initialization prevents a late listen', () async {
      final initialization = Completer<bool>();
      adapter.initializeCompleter = initialization;

      final start = service.startListening();
      await _waitFor(() => adapter.initializeCalls == 1);
      final stop = service.stopListening();
      initialization.complete(true);

      await Future.wait(<Future<void>>[start, stop]);

      expect(adapter.listenCalls, 0);
      expect(adapter.stopCalls, 0);
      expect(service.status, SpeechServiceStatus.ready);
    });

    test(
      'release during listen startup stops after startup resolves',
      () async {
        final listening = Completer<void>();
        adapter.listenCompleter = listening;

        final start = service.startListening();
        await _waitFor(() => adapter.listenCalls == 1);
        final stop = service.stopListening();
        listening.complete();

        await Future.wait(<Future<void>>[start, stop]);

        expect(adapter.listenCalls, 1);
        expect(adapter.stopCalls, 1);
        expect(service.status, SpeechServiceStatus.ready);
        expect(service.isListening, isFalse);
      },
    );

    test('replaces partials and replaces a corrected final result', () async {
      await service.startListening();

      adapter.emitResult(
        const SpeechRecognitionUpdate(transcript: 'hello', isFinal: false),
      );
      adapter.emitResult(
        const SpeechRecognitionUpdate(
          transcript: 'hello   world ',
          isFinal: false,
        ),
      );

      expect(service.partialTranscript, 'hello world');
      expect(service.transcript, 'hello world');

      adapter.emitResult(
        const SpeechRecognitionUpdate(transcript: '  ', isFinal: false),
      );
      expect(service.partialTranscript, isEmpty);

      adapter.emitResult(
        const SpeechRecognitionUpdate(
          transcript: 'hello world',
          isFinal: false,
        ),
      );

      adapter.emitResult(
        const SpeechRecognitionUpdate(
          transcript: 'hello world',
          isFinal: true,
          confidence: .81,
        ),
      );
      expect(service.partialTranscript, isEmpty);
      expect(service.finalTranscript, 'hello world');
      expect(service.confidence, .81);

      adapter.emitResult(
        const SpeechRecognitionUpdate(
          transcript: 'hello world again',
          isFinal: true,
          confidence: .93,
        ),
      );
      expect(service.finalTranscript, 'hello world again');
      expect(service.confidence, .93);
    });

    test('deduplicates repeated final callbacks within a session', () async {
      await service.startListening();
      var notifications = 0;
      service.addListener(() => notifications++);
      const finalResult = SpeechRecognitionUpdate(
        transcript: 'same result',
        isFinal: true,
        confidence: .9,
      );

      adapter.emitResult(finalResult);
      final notificationsAfterFirstResult = notifications;
      adapter.emitResult(finalResult);

      expect(service.finalTranscript, 'same result');
      expect(notifications, notificationsAfterFirstResult);
    });

    test('accepts a final result delivered while stopping', () async {
      await service.startListening();
      adapter.resultOnStop = const SpeechRecognitionUpdate(
        transcript: 'quick turn',
        isFinal: true,
        confidence: .88,
      );

      await service.stopListening();

      expect(service.finalTranscript, 'quick turn');
      expect(service.confidence, .88);
      expect(service.status, SpeechServiceStatus.ready);
    });

    test(
      'a terminal status from a stopped turn cannot cancel a restart',
      () async {
        await service.startListening();
        adapter.statusOnStop = 'notListening';

        final stop = service.stopListening();
        final restart = service.startListening();
        await Future.wait(<Future<void>>[stop, restart]);

        expect(adapter.listenCalls, 2);
        expect(service.status, SpeechServiceStatus.listening);
      },
    );

    test('dedupe is scoped to a turn and old callbacks are ignored', () async {
      await service.startListening();
      const result = SpeechRecognitionUpdate(
        transcript: 'repeat me',
        isFinal: true,
      );
      adapter.emitResult(result);
      await service.stopListening();

      await service.startListening();
      expect(service.finalTranscript, isEmpty);
      adapter.emitResultForSession(
        0,
        const SpeechRecognitionUpdate(
          transcript: 'stale result',
          isFinal: true,
        ),
      );
      expect(service.finalTranscript, isEmpty);

      adapter.emitResult(result);
      expect(service.finalTranscript, 'repeat me');
    });

    test('cancel clears the turn and ignores late results', () async {
      await service.startListening();
      adapter.emitResult(
        const SpeechRecognitionUpdate(
          transcript: 'discard this',
          isFinal: false,
        ),
      );

      await service.cancelListening();
      adapter.emitResult(
        const SpeechRecognitionUpdate(transcript: 'too late', isFinal: true),
      );

      expect(adapter.cancelCalls, 1);
      expect(service.transcript, isEmpty);
      expect(service.status, SpeechServiceStatus.ready);
    });

    test('ignores nonpermanent errors from completed turns', () async {
      const staleError = SpeechRecognitionErrorInfo(
        message: 'error_network_timeout',
        isPermanent: false,
      );

      await service.startListening();
      await service.stopListening();
      adapter.emitError(staleError);

      expect(service.status, SpeechServiceStatus.ready);
      expect(service.lastError, isNull);

      await service.startListening();
      await service.cancelListening();
      adapter.emitError(staleError);

      expect(service.status, SpeechServiceStatus.ready);
      expect(service.lastError, isNull);
    });

    test('forwards locale and duration options to the adapter', () async {
      adapter.availableLocales = const <SpeechLocale>[
        SpeechLocale(localeId: 'en_US', name: 'English'),
        SpeechLocale(localeId: 'id_ID', name: 'Bahasa Indonesia'),
      ];
      await service.initialize();

      expect(service.selectLocale('id_ID'), isTrue);
      expect(service.selectLocale('missing'), isFalse);
      await service.startListening(
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(milliseconds: 900),
      );

      expect(adapter.lastLocaleId, 'id_ID');
      expect(adapter.lastListenFor, const Duration(seconds: 8));
      expect(adapter.lastPauseFor, const Duration(milliseconds: 900));
    });

    test('surfaces platform errors and disposes the adapter', () async {
      await service.startListening();

      adapter.emitError(
        const SpeechRecognitionErrorInfo(
          message: 'error_permission',
          isPermanent: true,
        ),
      );

      expect(service.status, SpeechServiceStatus.error);
      expect(service.lastError?.message, 'error_permission');
      expect(service.isAvailable, isFalse);
      await _waitFor(() => !adapter.isListening);
      expect(adapter.isListening, isFalse);

      service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.disposeCalls, 1);
      expect(() => service.startListening(), throwsStateError);
    });

    test('contains adapter disposal failures', () async {
      adapter.disposeError = StateError('platform already detached');

      service.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.disposeCalls, 1);
    });
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached before the test timed out.');
}

class FakeSpeechRecognizerAdapter implements SpeechRecognizerAdapter {
  bool initializeResult = true;
  Object? initializeError;
  Object? stopError;
  Object? disposeError;
  Completer<bool>? initializeCompleter;
  Completer<void>? listenCompleter;
  List<SpeechLocale> availableLocales = const <SpeechLocale>[];
  SpeechLocale? currentSystemLocale;
  SpeechRecognitionUpdate? resultOnStop;
  String? statusOnStop;
  int initializeCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  String? lastLocaleId;
  Duration? lastListenFor;
  Duration? lastPauseFor;
  SpeechStatusCallback? _onStatus;
  SpeechErrorCallback? _onError;
  final List<SpeechResultCallback> _resultCallbacks = <SpeechResultCallback>[];

  @override
  bool isListening = false;

  @override
  Future<bool> initialize({
    required SpeechStatusCallback onStatus,
    required SpeechErrorCallback onError,
  }) async {
    initializeCalls++;
    _onStatus = onStatus;
    _onError = onError;
    final error = initializeError;
    if (error != null) throw error;
    return initializeCompleter?.future ?? initializeResult;
  }

  @override
  Future<List<SpeechLocale>> locales() async => availableLocales;

  @override
  Future<SpeechLocale?> systemLocale() async => currentSystemLocale;

  @override
  Future<void> listen({
    required SpeechResultCallback onResult,
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  }) async {
    listenCalls++;
    isListening = true;
    lastLocaleId = localeId;
    lastListenFor = listenFor;
    lastPauseFor = pauseFor;
    _resultCallbacks.add(onResult);
    await (listenCompleter?.future ?? Future<void>.value());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
    final pendingResult = resultOnStop;
    if (pendingResult != null) emitResult(pendingResult);
    isListening = false;
    final pendingStatus = statusOnStop;
    if (pendingStatus != null) emitStatus(pendingStatus);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    isListening = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    isListening = false;
    final error = disposeError;
    if (error != null) throw error;
  }

  void emitResult(SpeechRecognitionUpdate result) {
    if (_resultCallbacks.isNotEmpty) _resultCallbacks.last(result);
  }

  void emitResultForSession(int index, SpeechRecognitionUpdate result) {
    _resultCallbacks[index](result);
  }

  void emitStatus(String status) => _onStatus?.call(status);

  void emitError(SpeechRecognitionErrorInfo error) => _onError?.call(error);
}
