import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../models/hand_tracking_models.dart';

class WebHandTrackerBridge {
  final StreamController<HandTrackingFrame> _controller =
      StreamController<HandTrackingFrame>.broadcast();
  final StreamController<String> _healthController =
      StreamController<String>.broadcast();
  web.EventListener? _eventListener;
  web.EventListener? _healthEventListener;

  Stream<HandTrackingFrame> get frames => _controller.stream;

  /// Browser-only health events for a camera stream that ended or stopped
  /// producing MediaPipe results. No image or landmark data is included.
  Stream<String> get healthEvents => _healthController.stream;

  Future<void> start() async {
    _eventListener ??= ((web.Event event) {
      final detail = (event as web.CustomEvent).detail?.dartify();
      if (detail is! String) return;
      try {
        final json = jsonDecode(detail) as Map<String, dynamic>;
        if (!_controller.isClosed) {
          _controller.add(HandTrackingFrame.fromJson(json));
        }
      } on FormatException {
        // Ignore malformed frames; the next camera frame can recover.
      } on TypeError {
        // Ignore malformed frames; the next camera frame can recover.
      }
    }).toJS;
    web.window.addEventListener('signbridge-hand-frame', _eventListener);

    _healthEventListener ??= ((web.Event event) {
      final detail = (event as web.CustomEvent).detail?.dartify();
      if (detail is! String) return;
      try {
        final json = jsonDecode(detail) as Map<String, dynamic>;
        final state = json['state'];
        if (state is String && !_healthController.isClosed) {
          _healthController.add(state);
        }
      } on FormatException {
        // A malformed health event must not affect live hand tracking.
      } on TypeError {
        // A malformed health event must not affect live hand tracking.
      }
    }).toJS;
    web.window.addEventListener(
      'signbridge-hand-tracker-status',
      _healthEventListener,
    );

    final tracker = globalContext['signBridgeHandTracker'];
    if (tracker == null) {
      throw StateError('The web hand tracker script is not loaded.');
    }
    final promise = (tracker as JSObject).callMethodVarArgs<JSPromise<JSAny?>>(
      'start'.toJS,
      const <JSAny?>[],
    );
    await promise.toDart;
  }

  Future<void> stop() async {
    final tracker = globalContext['signBridgeHandTracker'];
    if (tracker != null) {
      final promise = (tracker as JSObject)
          .callMethodVarArgs<JSPromise<JSAny?>>('stop'.toJS, const <JSAny?>[]);
      await promise.toDart;
    }
  }

  void dispose() {
    if (_eventListener != null) {
      web.window.removeEventListener('signbridge-hand-frame', _eventListener);
    }
    if (_healthEventListener != null) {
      web.window.removeEventListener(
        'signbridge-hand-tracker-status',
        _healthEventListener,
      );
    }
    _controller.close();
    _healthController.close();
  }
}
