import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class WebCameraPreview extends StatelessWidget {
  WebCameraPreview({super.key}) {
    _registerViewFactory();
  }

  static bool _registered = false;

  static void _registerViewFactory() {
    if (_registered) return;
    ui_web.platformViewRegistry.registerViewFactory(
      'signbridge-camera',
      (int viewId) => web.HTMLVideoElement()
        ..setAttribute('data-signbridge-camera', 'true')
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        // The skeleton painters apply the same horizontal flip so the
        // overlay stays on the user's displayed hand.
        ..style.transform = 'scaleX(-1)',
    );
    _registered = true;
  }

  @override
  Widget build(BuildContext context) =>
      const HtmlElementView(viewType: 'signbridge-camera');
}
