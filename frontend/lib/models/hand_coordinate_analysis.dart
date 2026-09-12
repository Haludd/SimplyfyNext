import 'dart:math' as math;

import 'hand_tracking_models.dart';

/// Per-frame geometry derived from one tracked hand.
///
/// The values are wrist-centred. When MediaPipe supplies world landmarks they
/// are used; otherwise normalized image coordinates and relative z are used.
class HandCoordinateAnalysis {
  const HandCoordinateAnalysis({
    required this.handedness,
    required this.coordinateSpace,
    required this.jointCount,
    required this.centroidX,
    required this.centroidY,
    required this.centroidZ,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.minZ,
    required this.maxZ,
    required this.span,
  });

  final Handedness handedness;
  final String coordinateSpace;
  final int jointCount;
  final double centroidX;
  final double centroidY;
  final double centroidZ;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
  final double minZ;
  final double maxZ;
  final double span;

  double get depthRange => maxZ - minZ;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'handedness': handednessToString(handedness),
    'coordinate_space': coordinateSpace,
    'joint_count': jointCount,
    'centroid': <String, double>{
      'x': centroidX,
      'y': centroidY,
      'z': centroidZ,
    },
    'bounds': <String, dynamic>{
      'min_x': minX,
      'max_x': maxX,
      'min_y': minY,
      'max_y': maxY,
      'min_z': minZ,
      'max_z': maxZ,
    },
    'depth_range': depthRange,
    'span': span,
  };
}

class HandCoordinateAnalyzer {
  const HandCoordinateAnalyzer();

  List<HandCoordinateAnalysis> analyze(List<TrackedHand> hands) => hands
      .where((hand) => hand.landmarks.isNotEmpty)
      .map(_analyzeHand)
      .toList(growable: false);

  HandCoordinateAnalysis _analyzeHand(TrackedHand hand) {
    final hasWorldCoordinates = hand.landmarks.every(
      (landmark) =>
          landmark.worldX != null &&
          landmark.worldY != null &&
          landmark.worldZ != null,
    );
    final source = hasWorldCoordinates
        ? hand.landmarks
              .map(
                (landmark) => <double>[
                  landmark.worldX!,
                  landmark.worldY!,
                  landmark.worldZ!,
                ],
              )
              .toList(growable: false)
        : hand.landmarks
              .map((landmark) => <double>[landmark.x, landmark.y, landmark.z])
              .toList(growable: false);
    final wrist = source.first;
    final centered = source
        .map(
          (point) => <double>[
            point[0] - wrist[0],
            point[1] - wrist[1],
            point[2] - wrist[2],
          ],
        )
        .toList(growable: false);

    final centroid = <double>[0, 0, 0];
    for (final point in centered) {
      centroid[0] += point[0];
      centroid[1] += point[1];
      centroid[2] += point[2];
    }
    centroid[0] /= centered.length;
    centroid[1] /= centered.length;
    centroid[2] /= centered.length;

    final minX = centered.map((point) => point[0]).reduce(math.min);
    final maxX = centered.map((point) => point[0]).reduce(math.max);
    final minY = centered.map((point) => point[1]).reduce(math.min);
    final maxY = centered.map((point) => point[1]).reduce(math.max);
    final minZ = centered.map((point) => point[2]).reduce(math.min);
    final maxZ = centered.map((point) => point[2]).reduce(math.max);

    return HandCoordinateAnalysis(
      handedness: hand.handedness,
      coordinateSpace: hasWorldCoordinates
          ? 'world_wrist_centered'
          : 'image_normalized_wrist_centered',
      jointCount: centered.length,
      centroidX: centroid[0],
      centroidY: centroid[1],
      centroidZ: centroid[2],
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      minZ: minZ,
      maxZ: maxZ,
      span: math.sqrt(
        math.pow(maxX - minX, 2) +
            math.pow(maxY - minY, 2) +
            math.pow(maxZ - minZ, 2),
      ),
    );
  }
}
