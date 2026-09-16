import '../models/asl_recognition_models.dart';

/// Native platforms retain the existing tracking flow. The browser
/// implementation is selected by a conditional export.
class AslRecognizerBridge {
  bool get isSupported => false;

  Future<void> beginCapture() async {}

  Future<AslRecognitionResult?> finishCapture() async => null;

  Future<AslPersonalTemplateReceipt?> teachLastCapture(String label) async =>
      null;

  Future<void> reset() async {}

  void dispose() {}
}
