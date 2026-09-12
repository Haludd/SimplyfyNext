import '../models/hand_tracking_models.dart';

class WebHandTrackerBridge {
  Stream<HandTrackingFrame> get frames =>
      const Stream<HandTrackingFrame>.empty();

  Future<void> start() async {}

  Future<void> stop() async {}

  void dispose() {}
}
