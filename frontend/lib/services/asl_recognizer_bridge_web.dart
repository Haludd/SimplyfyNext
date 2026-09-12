import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../models/asl_recognition_models.dart';

/// Calls the local JavaScript ONNX adapter. The adapter owns the full 543-point
/// MediaPipe input inside the page and returns only a compact recognition
/// result to Flutter.
class AslRecognizerBridge {
  bool get isSupported => globalContext['signBridgeAslRecognizer'] != null;

  Future<void> beginCapture() => _invokeVoid('beginCapture');

  Future<void> reset() => _invokeVoid('reset');

  Future<AslRecognitionResult?> finishCapture() async {
    final recognizer = _recognizer;
    if (recognizer == null) return null;
    final promise = recognizer.callMethodVarArgs<JSPromise<JSAny?>>(
      'finishCapture'.toJS,
      const <JSAny?>[],
    );
    final raw = await promise.toDart;
    final decoded = raw?.dartify();
    if (decoded is! Map) return null;
    return AslRecognitionResult.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Saves an explicitly approved correction for the most recently completed
  /// capture in browser storage. The JavaScript adapter keeps the normalized
  /// landmark signature local; Flutter receives only this compact receipt.
  Future<AslPersonalTemplateReceipt?> teachLastCapture(String label) async {
    final recognizer = _recognizer;
    if (recognizer == null) return null;
    final promise = recognizer.callMethodVarArgs<JSPromise<JSAny?>>(
      'teachLastCapture'.toJS,
      <JSAny?>[label.toJS],
    );
    final raw = await promise.toDart;
    final decoded = raw?.dartify();
    if (decoded is! Map) return null;
    return AslPersonalTemplateReceipt.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  void dispose() {
    // The page-level ONNX session is deliberately cached across Flutter widget
    // rebuilds. reset() discards only an unfinished signer capture.
  }

  JSObject? get _recognizer {
    final value = globalContext['signBridgeAslRecognizer'];
    return value?.isA<JSObject>() == true ? value as JSObject : null;
  }

  Future<void> _invokeVoid(String method) async {
    final recognizer = _recognizer;
    if (recognizer == null) return;
    final promise = recognizer.callMethodVarArgs<JSPromise<JSAny?>>(
      method.toJS,
      const <JSAny?>[],
    );
    await promise.toDart;
  }
}
