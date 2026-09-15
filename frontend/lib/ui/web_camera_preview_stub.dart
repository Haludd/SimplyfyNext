import 'package:flutter/material.dart';

class WebCameraPreview extends StatelessWidget {
  const WebCameraPreview({super.key});

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.black26,
    child: Center(
      child: Text('Web camera preview is only available in Chrome.'),
    ),
  );
}
