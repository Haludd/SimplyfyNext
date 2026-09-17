import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/landmark_frame.dart';
import 'camera_overlay_projection.dart';
import 'theme.dart';
import 'web_camera_preview.dart';

bool isRenderablePoint(double x, double y, double visibility) =>
    visibility >= .35 &&
    x.isFinite &&
    y.isFinite &&
    x >= 0 &&
    x <= 1 &&
    y >= 0 &&
    y <= 1;

NormalizedPoint? _renderablePoint(NormalizedPoint? point) =>
    point != null && isRenderablePoint(point.x, point.y, point.visibility)
    ? point
    : null;

/// Landmarks are drawn as a solid core with a soft halo so they stay legible
/// over bright and dark video alike.
const double _coreAlpha = 1;
const double _haloAlpha = .18;
const double _boneAlpha = .7;

/// The live camera feed with the tracking overlay painted on top.
///
/// It always fills its parent with a `BoxFit.cover` crop, which is the same
/// transform [CameraOverlayProjection] applies to the landmarks, so a dot stays
/// on its source pixel at any screen shape.
class CameraStage extends StatelessWidget {
  const CameraStage({
    super.key,
    required this.controller,
    this.showCalibrationGuide = false,
  });

  final AppController controller;
  final bool showCalibrationGuide;

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller.devices.cameraReady;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (cameraReady)
            _CameraFeed(controller: controller)
          else
            const ColoredBox(color: Sb.cameraVoid),
          if (cameraReady && controller.viewMode != ViewMode.raw)
            CustomPaint(
              painter: LandmarkPainter(
                controller.latestFrame,
                showCalibrationGuide: showCalibrationGuide,
              ),
            ),
          if (cameraReady && controller.viewMode == ViewMode.wireframe)
            CustomPaint(painter: HandSkeletonPainter(controller.latestFrame)),
        ],
      ),
    );
  }
}

class _CameraFeed extends StatelessWidget {
  const _CameraFeed({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // The HTML video element already applies `object-fit: cover`.
      return WebCameraPreview();
    }
    final camera = controller.devices.cameraController;
    if (camera == null || !camera.value.isInitialized) {
      return const ColoredBox(color: Sb.cameraVoid);
    }
    final preview = camera.value.previewSize;
    // `previewSize` is reported in sensor orientation, so its axes are swapped
    // for a portrait preview.
    final width = preview?.height ?? 720;
    final height = preview?.width ?? 1280;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: width,
        height: height,
        child: CameraPreview(camera),
      ),
    );
  }
}

class LandmarkPainter extends CustomPainter {
  LandmarkPainter(this.frame, {this.showCalibrationGuide = false});

  final LandmarkFrame? frame;
  final bool showCalibrationGuide;

  @override
  void paint(Canvas canvas, Size size) {
    final projection = CameraOverlayProjection(
      displaySize: size,
      camera: frame?.cameraGeometry,
    );
    final linePaint = Paint()
      ..color = Sb.trackingPrimary.withValues(alpha: .55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final leftShoulder = _renderablePoint(frame?.leftShoulder);
    final rightShoulder = _renderablePoint(frame?.rightShoulder);
    final leftWrist = _renderablePoint(frame?.leftWrist);
    final rightWrist = _renderablePoint(frame?.rightWrist);
    final personDetected =
        frame != null &&
        (frame!.poseLandmarks.isNotEmpty ||
            frame!.hands.isNotEmpty ||
            frame!.faceUpperLandmarks.isNotEmpty ||
            frame!.faceMouthLandmarks.isNotEmpty);
    final actualAnchorPoints = <NormalizedPoint?>[
      leftShoulder,
      rightShoulder,
      leftWrist,
      rightWrist,
    ];
    if (leftShoulder != null && rightShoulder != null) {
      canvas.drawLine(
        projection.project(leftShoulder.x, leftShoulder.y),
        projection.project(rightShoulder.x, rightShoulder.y),
        linePaint,
      );
    }
    if (leftShoulder != null && leftWrist != null) {
      canvas.drawLine(
        projection.project(leftShoulder.x, leftShoulder.y),
        projection.project(leftWrist.x, leftWrist.y),
        linePaint,
      );
    }
    if (rightShoulder != null && rightWrist != null) {
      canvas.drawLine(
        projection.project(rightShoulder.x, rightShoulder.y),
        projection.project(rightWrist.x, rightWrist.y),
        linePaint,
      );
    }
    var anchorPoints = actualAnchorPoints.whereType<NormalizedPoint>().toList();
    if (showCalibrationGuide && personDetected && anchorPoints.isEmpty) {
      anchorPoints = <NormalizedPoint>[
        const NormalizedPoint(x: .39, y: .35),
        const NormalizedPoint(x: .61, y: .35),
        const NormalizedPoint(x: .25, y: .72),
        const NormalizedPoint(x: .75, y: .72),
      ];
      canvas.drawLine(
        projection.project(anchorPoints[0].x, anchorPoints[0].y),
        projection.project(anchorPoints[1].x, anchorPoints[1].y),
        linePaint,
      );
      canvas.drawLine(
        projection.project(anchorPoints[0].x, anchorPoints[0].y),
        projection.project(anchorPoints[2].x, anchorPoints[2].y),
        linePaint,
      );
      canvas.drawLine(
        projection.project(anchorPoints[1].x, anchorPoints[1].y),
        projection.project(anchorPoints[3].x, anchorPoints[3].y),
        linePaint,
      );
    }
    for (final point in anchorPoints) {
      final offset = projection.project(point.x, point.y);
      // A detected point stays solid on screen. Its confidence remains in
      // LandmarkFrame; the UI never turns a real point into a prediction.
      canvas.drawCircle(
        offset,
        5,
        Paint()..color = Sb.trackingPrimary.withValues(alpha: _coreAlpha),
      );
      canvas.drawCircle(
        offset,
        10,
        Paint()..color = Sb.trackingPrimary.withValues(alpha: _haloAlpha),
      );
    }

    // Draw the curated pose world as a connected upper-body skeleton.
    final pose = frame?.poseLandmarks ?? const <PoseLandmark>[];
    final poseByIndex = <int, PoseLandmark>{
      for (final landmark in pose) landmark.index: landmark,
    };
    const poseEdges = <List<int>>[
      <int>[11, 13],
      <int>[13, 15],
      <int>[12, 14],
      <int>[14, 16],
      <int>[11, 12],
      <int>[11, 23],
      <int>[12, 24],
      <int>[23, 24],
      <int>[23, 25],
      <int>[24, 26],
    ];
    for (final edge in poseEdges) {
      final first = poseByIndex[edge[0]];
      final second = poseByIndex[edge[1]];
      if (first == null ||
          second == null ||
          !isRenderablePoint(first.x, first.y, first.visibility) ||
          !isRenderablePoint(second.x, second.y, second.visibility)) {
        continue;
      }
      canvas.drawLine(
        projection.project(first.x, first.y),
        projection.project(second.x, second.y),
        Paint()
          ..color = Sb.trackingPrimary.withValues(alpha: _boneAlpha)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
    }
    for (final landmark in pose) {
      if (!isRenderablePoint(landmark.x, landmark.y, landmark.visibility)) {
        continue;
      }
      canvas.drawCircle(
        projection.project(landmark.x, landmark.y),
        3.5,
        Paint()..color = Sb.trackingPrimary.withValues(alpha: _coreAlpha),
      );
    }

    // Face points use the same two accents as the pose and hand worlds.
    for (final landmark
        in frame?.faceUpperLandmarks ?? const <FaceLandmark>[]) {
      if (!isRenderablePoint(landmark.x, landmark.y, landmark.visibility)) {
        continue;
      }
      canvas.drawCircle(
        projection.project(landmark.x, landmark.y),
        2.5,
        Paint()..color = Sb.trackingPrimary.withValues(alpha: _coreAlpha),
      );
    }
    for (final landmark
        in frame?.faceMouthLandmarks ?? const <FaceLandmark>[]) {
      if (!isRenderablePoint(landmark.x, landmark.y, landmark.visibility)) {
        continue;
      }
      canvas.drawCircle(
        projection.project(landmark.x, landmark.y),
        2.5,
        Paint()..color = Sb.trackingSecondary.withValues(alpha: _coreAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant LandmarkPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.showCalibrationGuide != showCalibrationGuide;
}

class HandSkeletonPainter extends CustomPainter {
  HandSkeletonPainter(this.frame);

  final LandmarkFrame? frame;

  @override
  void paint(Canvas canvas, Size size) {
    final projection = CameraOverlayProjection(
      displaySize: size,
      camera: frame?.cameraGeometry,
    );
    final hands = frame?.hands ?? const <TrackedHand>[];
    for (final hand in hands) {
      final color = hand.handedness == Handedness.left
          ? Sb.trackingSecondary
          : Sb.trackingPrimary;
      for (final edge in handLandmarkEdges) {
        if (edge.any((index) => index >= hand.landmarks.length)) continue;
        final first = hand.landmarks[edge[0]];
        final second = hand.landmarks[edge[1]];
        if (!isRenderablePoint(first.x, first.y, first.visibility) ||
            !isRenderablePoint(second.x, second.y, second.visibility)) {
          continue;
        }
        canvas.drawLine(
          projection.project(first.x, first.y),
          projection.project(second.x, second.y),
          Paint()
            ..color = color.withValues(alpha: _boneAlpha)
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
      for (final landmark in hand.landmarks) {
        if (!isRenderablePoint(landmark.x, landmark.y, landmark.visibility)) {
          continue;
        }
        final point = projection.project(landmark.x, landmark.y);
        final radius = (4.5 - landmark.z.abs() * 8).clamp(2.5, 5.5);
        canvas.drawCircle(
          point,
          radius,
          Paint()..color = color.withValues(alpha: _coreAlpha),
        );
        canvas.drawCircle(
          point,
          radius + 4,
          Paint()..color = color.withValues(alpha: _haloAlpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant HandSkeletonPainter oldDelegate) =>
      oldDelegate.frame != frame;
}
