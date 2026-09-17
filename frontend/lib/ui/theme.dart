import 'package:flutter/material.dart';

/// Design tokens for the SignBridge interface.
///
/// The app is intentionally light, quiet, and typographic: white surfaces, a
/// sky-blue accent pair, and colour reserved for signal (confidence, errors).
/// Any screen that shows the camera inverts this and paints its few controls
/// on translucent light chips so the video stays the subject.
abstract final class Sb {
  // Surfaces
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF1F2F5);
  static const surfaceStrong = Color(0xFFE6E8ED);
  static const border = Color(0xFFE4E6EB);

  // Brand — the darker of the two sky blues fills interactive surfaces
  // (buttons, the send bubble); the lighter one is its calmer companion for
  // secondary chips and highlights. Both are pastel, so neither is dark
  // enough for text or an icon to sit directly on white — primaryStrong is
  // the same hue deepened until it reads as real text (5.2:1 on white).
  static const primary = Color(0xFF89C2D9);
  static const primarySoft = Color(0xFFA9D6E5);
  static const primaryStrong = Color(0xFF2C7496);

  // Text
  static const text = Color(0xFF0B0D12);
  static const textMuted = Color(0xFF8A8F9A);
  static const textFaint = Color(0xFFB2B7C0);

  // Signal — same soft, mid-light saturation as the brand blues so a
  // confidence dot or a warning reads as part of one palette, not a clash.
  static const good = Color(0xFF52B788);
  static const warn = Color(0xFFE3A857);
  static const bad = Color(0xFFE2707A);

  // Camera overlay
  static const overlay = Color(0xE8FFFFFF);
  static const overlayChip = Color(0xB3FFFFFF);
  static const cameraVoid = Color(0xFF12151C);

  // Landmarks use the same accent pair as the rest of the app.
  static const trackingPrimary = Color(0xFF89C2D9);
  static const trackingSecondary = Color(0xFFA9D6E5);

  static const radius = 16.0;
  static const radiusLarge = 22.0;
  static const gutter = 20.0;

  /// Traffic-light colour for a 0..1 confidence value.
  static Color confidenceColor(double value) => value >= .80
      ? good
      : value >= .60
      ? warn
      : bad;

  static String percent(double value) =>
      '${(value.clamp(0.0, 1.0) * 100).round()}%';
}

ThemeData signBridgeTheme() {
  const scheme = ColorScheme.light(
    primary: Sb.primary,
    // The accent is a light sky blue, too pale for white text to sit on
    // legibly — dark text/icons stay readable on it at every size.
    onPrimary: Sb.text,
    secondary: Sb.primarySoft,
    onSecondary: Sb.text,
    surface: Sb.background,
    onSurface: Sb.text,
    error: Sb.bad,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Sb.background,
    fontFamily: 'Avenir Next',
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Sb.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Sb.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Sb.text,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Sb.border,
      thickness: 1,
      space: 1,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Sb.text,
      displayColor: Sb.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Sb.surface,
      hintStyle: const TextStyle(color: Sb.textMuted, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
        borderSide: const BorderSide(color: Sb.primaryStrong, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
        borderSide: const BorderSide(color: Sb.bad, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
        borderSide: const BorderSide(color: Sb.bad, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Sb.primary,
        // Dark text: the accent is too light for white to read on.
        foregroundColor: Sb.text,
        disabledBackgroundColor: Sb.surfaceStrong,
        disabledForegroundColor: Sb.textFaint,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Sb.radius),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        // primaryStrong, not primary: this renders as text on white.
        foregroundColor: Sb.primaryStrong,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Sb.text,
        side: const BorderSide(color: Sb.border),
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Sb.radius),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Sb.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 62,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? Sb.primaryStrong
              : Sb.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? Sb.primaryStrong
              : Sb.textMuted,
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Sb.background,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
      ),
      textStyle: const TextStyle(color: Sb.text, fontSize: 15),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Sb.background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Sb.surfaceStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Sb.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Sb.radiusLarge),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Sb.text,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Sb.radius),
      ),
    ),
  );
}

/// A small filled dot that encodes a 0..1 confidence as red / amber / green.
class ConfidenceDot extends StatelessWidget {
  const ConfidenceDot({super.key, required this.confidence, this.size = 9});

  final double confidence;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Sb.confidenceColor(confidence);
    return Semantics(
      label: 'Recognition confidence ${Sb.percent(confidence)}',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A circular control drawn on top of the camera feed.
class CameraIconButton extends StatelessWidget {
  const CameraIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 44,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Sb.overlayChip,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * .45, color: Sb.text),
        ),
      ),
    ),
  );
}

/// Section label used inside bottom sheets and settings lists.
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Sb.gutter, 2, Sb.gutter, 12),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

/// Opens a rounded, scrollable sheet sized to its content.
Future<T?> showSbSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Sb.background,
  builder: (sheetContext) => Padding(
    padding: EdgeInsets.only(
      bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
    ),
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * .86,
        ),
        child: builder(sheetContext),
      ),
    ),
  ),
);
