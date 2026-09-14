import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../models/asl_recognition_models.dart';

/// Captures a short browser landmark clip and classifies it locally with the
/// Signchat ONNX model through ONNX Runtime Web.
class AslRecognizerBridge {
  bool get isSupported => _recognizer != null;

  Future<void> beginCapture() => _invokeVoid('beginSignCapture');

  Future<void> reset() => _invokeVoid('resetSignCapture');

  Future<AslRecognitionResult?> finishCapture() async {
    final recognizer = _recognizer;
    if (recognizer == null) return null;
    final promise = recognizer.callMethodVarArgs<JSPromise<JSAny?>>(
      'finishSignCapture'.toJS,
      const <JSAny?>[],
    );
    final raw = await promise.toDart;
    final decoded = raw?.dartify();
    if (decoded is! Map) return null;
    return AslRecognitionResult.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Kept for API compatibility with the older correction UI. The classifier
  /// uses its shipped browser model, so browser-local templates are not used.
  Future<AslPersonalTemplateReceipt?> teachLastCapture(String label) async {
    return null;
  }

  JSObject? get _recognizer {
    final value = globalContext['signBridgeLocalAslClassifier'];
    return value?.isA<JSObject>() == true ? value as JSObject : null;
  }

  void dispose() {}

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
