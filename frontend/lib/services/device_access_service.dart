import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class DeviceAccessService extends ChangeNotifier {
  CameraController? cameraController;
  bool _webCameraReady = false;
  PermissionStatus microphonePermission = PermissionStatus.denied;
  bool isTestingMicrophone = false;
  String cameraName = 'Default camera';
  String cameraStatus = 'Not enabled';

  bool get cameraReady =>
      kIsWeb ? _webCameraReady : cameraController?.value.isInitialized == true;
  String get microphoneStatus =>
      microphonePermission == PermissionStatus.granted
      ? 'Ready'
      : 'Permission needed';

  Future<void> enableCamera() async {
    if (kIsWeb) {
      // Chrome owns getUserMedia for the web tracker. The permission prompt is
      // requested by web/hand_tracking.js so the video and detector share one
      // stream instead of opening two camera sessions.
      _webCameraReady = true;
      cameraName = 'Chrome camera';
      cameraStatus = 'Starting...';
      notifyListeners();
      return;
    }
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      cameraStatus = 'Permission needed';
      notifyListeners();
      return;
    }

    try {
      final available = await availableCameras();
      if (available.isEmpty) {
        cameraStatus = 'No camera found';
        notifyListeners();
        return;
      }
      final selected = available.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => available.first,
      );
      await cameraController?.dispose();
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      cameraController = controller;
      cameraName = selected.name;
      cameraStatus = 'Ready';
    } on CameraException catch (error) {
      cameraStatus = error.description ?? error.code;
    } catch (_) {
      cameraStatus = 'Camera unavailable';
    }
    notifyListeners();
  }

  /// Releases the active camera stream and marks the camera as unavailable.
  /// On web, the MediaPipe bridge owns the actual stream; the controller stops
  /// tracking before calling this method.
  Future<void> disableCamera() async {
    if (kIsWeb) {
      _webCameraReady = false;
      cameraStatus = 'Camera off';
      notifyListeners();
      return;
    }

    final activeController = cameraController;
    cameraController = null;
    await activeController?.dispose();
    cameraStatus = 'Not enabled';
    notifyListeners();
  }

  void markWebCameraUnavailable([String status = 'Camera unavailable']) {
    if (!kIsWeb) return;
    _webCameraReady = false;
    cameraStatus = status;
    notifyListeners();
  }

  Future<void> enableMicrophone() async {
    microphonePermission = await Permission.microphone.request();
    notifyListeners();
  }

  Future<void> testMicrophone() async {
    if (!microphonePermission.isGranted) {
      await enableMicrophone();
    }
    if (!microphonePermission.isGranted) return;
    isTestingMicrophone = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(seconds: 2));
    isTestingMicrophone = false;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(cameraController?.dispose());
    cameraController = null;
    super.dispose();
  }
}
