import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../contracts/landmark_stream.dart';

/// Projects canonical camera coordinates into a `BoxFit.cover` preview.
///
/// The web video preview mirrors itself horizontally and crops either side or
/// top/bottom to fill its Flutter box. Overlay landmarks use this same
/// transform, so a dot remains on its source pixel at every preview aspect
/// ratio.
class CameraOverlayProjection {
  const CameraOverlayProjection({
    required this.displaySize,
    this.camera,
    this.mirrorX = true,
  });

  final Size displaySize;
  final LandmarkCameraGeometry? camera;
  final bool mirrorX;

  Offset project(double x, double y) {
    final sourceWidth = math.max(
      1.0,
      (camera?.sourceWidth ?? displaySize.width.round()).toDouble(),
    );
    final sourceHeight = math.max(
      1.0,
      (camera?.sourceHeight ?? displaySize.height.round()).toDouble(),
    );
    final scale = math.max(
      displaySize.width / sourceWidth,
      displaySize.height / sourceHeight,
    );
    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;
    final unmirroredX =
        x * renderedWidth - (renderedWidth - displaySize.width) / 2;
    final projectedY =
        y * renderedHeight - (renderedHeight - displaySize.height) / 2;
    return Offset(
      mirrorX ? displaySize.width - unmirroredX : unmirroredX,
      projectedY,
    );
  }
}
