import 'package:flutter/material.dart';

/// Terracotta / kiremit palette — istanbul's historic rooftops and stone —
/// ported verbatim from prototype/styles.css's `:root` tokens. This is the
/// approved visual direction (docs/design/implementation-contract.md); it
/// replaced an earlier pastel-purple pass that this app's theme had drifted
/// back toward before the issue #21 prototype-parity correction.
class AppColors {
  static const bg = Color(0xFFF7F1E8);
  static const bgElevated = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEEE6DA);

  static const ink = Color(0xFF2A1F1B);
  static const muted = Color(0xFF6E5A4C);
  static const faint = Color(0xFFA5927E);

  static const primary = Color(0xFFA44732);
  static const primaryStrong = Color(0xFF773225);
  static const primarySoft = Color(0xFFF1DCD2);
  static const primaryInk = Color(0xFFFFFFFF);

  // needs-help is deliberately its own hue, never a shade of primary/accent,
  // so a cat in trouble never reads as just another highlight.
  static const help = Color(0xFFC7352B);
  static const helpStrong = Color(0xFF97231B);
  static const helpSoft = Color(0xFFF7DAD6);
  static const helpInk = Color(0xFFFFFFFF);

  static const line = Color(0xFFE4D8C4);
  static const lineStrong = Color(0xFFD2C1A6);

  static const overlay = Color(0x802A1F1B); // rgba(42,31,27,.5)
}

/// 4/8-based spacing scale (prototype/styles.css `--space-*`).
class AppSpacing {
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 20.0;
  static const s6 = 24.0;
  static const s8 = 32.0;
  static const s10 = 40.0;
  static const s12 = 48.0;
}

class AppRadius {
  static const sm = 8.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const full = 999.0;
}

/// Minimum touch target (prototype/styles.css `--tap-min`).
const kTapMin = 44.0;

const _fontDisplay = 'Fraunces';
const _fontBody = 'Work Sans';

class AppTheme {
  // The prototype has no dark-mode design of its own (product hasn't
  // decided on one) — dark deliberately mirrors light rather than
  // inventing an undesigned palette.
  static ThemeData light = _build();
  static ThemeData dark = _build();

  static ThemeData _build() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.bg,
      fontFamily: _fontBody,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        onPrimary: AppColors.primaryInk,
        secondary: AppColors.primaryStrong,
        onSecondary: AppColors.primaryInk,
        surface: AppColors.surface,
        onSurface: AppColors.ink,
        error: AppColors.help,
        onError: AppColors.helpInk,
        outline: AppColors.lineStrong,
      ),
      textTheme: const TextTheme(
        // Fraunces: screen titles and cat names.
        headlineSmall: TextStyle(
          fontFamily: _fontDisplay,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        titleLarge: TextStyle(
          fontFamily: _fontDisplay,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        titleMedium: TextStyle(
          fontFamily: _fontDisplay,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        // Work Sans: everything else.
        bodyLarge: TextStyle(fontFamily: _fontBody, color: AppColors.ink),
        bodyMedium: TextStyle(fontFamily: _fontBody, color: AppColors.ink),
        bodySmall: TextStyle(fontFamily: _fontBody, color: AppColors.muted),
        labelSmall: TextStyle(fontFamily: _fontBody, color: AppColors.faint),
      ),
    );
  }
}
