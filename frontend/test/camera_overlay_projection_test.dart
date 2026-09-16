import 'package:apptesting/contracts/landmark_stream.dart';
import 'package:apptesting/ui/camera_overlay_projection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cover projection mirrors and crops points exactly like the web video',
    () {
      const projection = CameraOverlayProjection(
        displaySize: Size(390, 390),
        camera: LandmarkCameraGeometry(
          sourceWidth: 640,
          sourceHeight: 480,
          mirroredInput: false,
        ),
      );

      // A 4:3 camera covering a square view is 65 pixels cropped at each side.
      expect(projection.project(.125, .5), const Offset(390, 195));
      expect(projection.project(.875, .5), const Offset(0, 195));
      expect(projection.project(.5, 0), const Offset(195, 0));
    },
  );
}
