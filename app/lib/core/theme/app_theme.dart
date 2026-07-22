import 'package:flutter/material.dart';

/// Colors only, from docs/design/visual-direction.md — that doc itself
/// flags every value as a first draft, not a locked decision. Fonts
/// (Fraunces/Work Sans) need self-hosting and are left for when a real
/// screen needs them.
class AppColors {
  static const ink = Color(0xFF14181F);
  static const inkDark = Color(0xFF0E1116);
  static const paper = Color(0xFFEEF0F0);
  static const panel = Color(0xFFFFFFFF);
  static const accent = Color(0xFFD9862A);
  static const accentDark = Color(0xFFEDA63F);
  static const line = Color(0xFF9AA1A6);
}

class AppTheme {
  static ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.paper,
    colorScheme: ColorScheme.light(
      primary: AppColors.accent,
      onPrimary: AppColors.panel,
      surface: AppColors.panel,
      onSurface: AppColors.ink,
      outline: AppColors.line,
    ),
  );

  static ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.inkDark,
    colorScheme: ColorScheme.dark(
      primary: AppColors.accentDark,
      onPrimary: AppColors.inkDark,
      surface: AppColors.ink,
      onSurface: AppColors.paper,
      outline: AppColors.line,
    ),
  );
}
