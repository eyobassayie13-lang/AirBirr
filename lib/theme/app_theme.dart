import 'package:flutter/material.dart';

/// Central theme definitions for the AirBirr (OffPay) application.
///
/// Implements both Material 3 Light and Dark themes dynamically supporting ThemeMode.system:
///
/// Dark Theme:
/// - Background: Deep Charcoal (#121212)
/// - Surfaces: Elevated Dark Gray (#1E1E1E) with subtle borders (#2C2C2C)
/// - Accents: Electric Cyan (#00E5FF) and Mint Green (#00E676)
/// - Offline Indicator: Muted Yellow (#FFD54F)
///
/// Light Theme:
/// - Background: Clean Off-White (#F8F9FA)
/// - Surfaces: Pure White (#FFFFFF) with subtle border (#E0E0E0)
/// - Accents: Clean Cyan (#00B4D8) and Mint Green (#00C853)
/// - Offline Indicator: Warm Amber (#F57F17)
class AppTheme {
  // Dark Palette
  static const Color darkBackground = Color(0xFF0D0D0E);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkSurfaceElevated = Color(0xFF252525);
  static const Color darkSurfaceElevatedHigh = Color(0xFF2C2C2C);
  static const Color darkCardBorder = Color(0xFF2C2C2C);
  static const Color darkSubtleBorder = Color(0xFF383838);
  static const Color darkPrimaryAccent = Color(0xFF00E5FF); // Electric Cyan
  static const Color darkMintGreen = Color(0xFF00E676); // Mint Green (Success / Balance)
  // Offline & Status Palette
  static const Color darkMutedYellow = Color(0xFFFFD54F); // Muted Yellow (Offline Dark)
  static const Color mutedActionGray = Color(0xFF9E9E9E); // Muted Online-Only Action Gray

  // Typography Tokens
  static const List<FontFeature> tabularFigures = [FontFeature.tabularFigures()];

  /// Returns a copy of [style] with tabular figures enabled for non-jittering numerals.
  static TextStyle withTabularFigures(TextStyle? style) {
    final base = style ?? const TextStyle();
    return base.copyWith(fontFeatures: [...?base.fontFeatures, const FontFeature.tabularFigures()]);
  }
  static const Color darkMediumGray = Color(0xFF9E9E9E); // Medium Gray
  static const Color darkSentRed = Color(0xFFFF5252);
  static const Color darkError = Color(0xFFCF6679);

  // Light Palette
  static const Color lightBackground = Color(0xFFF8F9FA); // Clean Off-White
  static const Color lightSurface = Color(0xFFFFFFFF); // Pure White
  static const Color lightSurfaceElevated = Color(0xFFF1F3F5);
  static const Color lightSurfaceElevatedHigh = Color(0xFFE9ECEF);
  static const Color lightCardBorder = Color(0xFFE0E0E0);
  static const Color lightSubtleBorder = Color(0xFFE5E7EB);
  static const Color lightPrimaryAccent = Color(0xFF00B4D8); // Clean Cyan
  static const Color lightMintGreen = Color(0xFF00C853); // Mint Green (Success / Balance)
  static const Color lightWarmAmber = Color(0xFFF57F17); // Warm Amber (Offline)
  static const Color lightMediumGray = Color(0xFF757575);
  static const Color lightSentRed = Color(0xFFD32F2F);
  static const Color lightError = Color(0xFFB00020);

  // Backward-compatible aliases (defaults to dark palette values)
  static const Color background = darkBackground;
  static const Color surface = darkSurface;
  static const Color surfaceElevated = darkSurfaceElevated;
  static const Color surfaceElevatedHigh = darkSurfaceElevatedHigh;
  static const Color cardBorder = darkCardBorder;
  static const Color subtleBorder = darkSubtleBorder;
  static const Color primaryAccent = darkPrimaryAccent;
  static const Color mintGreen = darkMintGreen;
  static const Color mutedYellow = darkMutedYellow;
  static const Color mediumGray = darkMediumGray;
  static const Color darkGray = Color(0xFF616161);
  static const Color sentRed = darkSentRed;
  static const Color error = darkError;
  static const Color warmAmber = lightWarmAmber;
  static const Color mutedAction = mutedActionGray;

  /// Returns the offline warning indicator color based on brightness.
  static Color offlineColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkMutedYellow : lightWarmAmber;

  /// Returns the online success indicator color based on brightness.
  static Color onlineColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkMintGreen : lightMintGreen;

  /// Returns the primary cyan accent based on brightness.
  static Color accentColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkPrimaryAccent : lightPrimaryAccent;

  /// Returns the surface color based on brightness.
  static Color surfaceColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkSurface : lightSurface;

  /// Returns the card border color based on brightness.
  static Color borderColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkCardBorder : lightCardBorder;

  /// Complete Dark Theme definition for MaterialApp.
  static ThemeData get darkTheme {
    final colorScheme = const ColorScheme.dark().copyWith(
      primary: darkPrimaryAccent,
      onPrimary: Colors.black,
      secondary: darkMintGreen,
      onSecondary: Colors.black,
      surface: darkSurface,
      onSurface: Colors.white,
      error: darkError,
      onError: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: colorScheme,

      // AppBar Theme
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: Colors.white),
      ),

      // Card Theme
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 1,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: darkCardBorder, width: 1),
        ),
      ),

      // Segmented Button Theme
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return darkPrimaryAccent.withValues(alpha: 0.18);
            }
            return darkSurfaceElevated;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return darkPrimaryAccent;
            }
            return darkMediumGray;
          }),
          side: WidgetStateProperty.all(
            const BorderSide(color: darkCardBorder, width: 1),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
      ),

      // Input Decoration Theme
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceElevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: const TextStyle(color: darkMediumGray, fontSize: 13),
        hintStyle: const TextStyle(color: darkGray, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkSubtleBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkSubtleBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkPrimaryAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkError),
        ),
      ),

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: darkSurface,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: darkCardBorder, width: 1),
        ),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(
          color: Color(0xFFE0E0E0),
          fontSize: 14,
        ),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: darkSurface,
        modalBackgroundColor: darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: darkCardBorder, width: 1),
        ),
      ),

      // SnackBar Theme
      snackBarTheme: SnackBarThemeData(
        backgroundColor: darkSurfaceElevatedHigh,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: darkSubtleBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // FilledButton Theme
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),

      // OutlinedButton Theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: darkSubtleBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),

      dividerColor: darkCardBorder,
    );
  }

  /// Complete Light Theme definition for MaterialApp.
  static ThemeData get lightTheme {
    final colorScheme = const ColorScheme.light().copyWith(
      primary: lightPrimaryAccent,
      onPrimary: Colors.white,
      secondary: lightMintGreen,
      onSecondary: Colors.white,
      surface: lightSurface,
      onSurface: const Color(0xFF212121),
      error: lightError,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBackground,
      colorScheme: colorScheme,

      // AppBar Theme
      appBarTheme: const AppBarTheme(
        backgroundColor: lightSurface,
        foregroundColor: Color(0xFF212121),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF212121),
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: Color(0xFF212121)),
      ),

      // Card Theme
      cardTheme: CardThemeData(
        color: lightSurface,
        elevation: 0.5,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: lightCardBorder, width: 1),
        ),
      ),

      // Segmented Button Theme
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return lightPrimaryAccent.withValues(alpha: 0.15);
            }
            return lightSurfaceElevated;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return lightPrimaryAccent;
            }
            return lightMediumGray;
          }),
          side: WidgetStateProperty.all(
            const BorderSide(color: lightCardBorder, width: 1),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
      ),

      // Input Decoration Theme
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSurfaceElevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: const TextStyle(color: lightMediumGray, fontSize: 13),
        hintStyle: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: lightCardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: lightCardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: lightPrimaryAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: lightError),
        ),
      ),

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: lightSurface,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: lightCardBorder, width: 1),
        ),
        titleTextStyle: const TextStyle(
          color: Color(0xFF212121),
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(
          color: Color(0xFF424242),
          fontSize: 14,
        ),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: lightSurface,
        modalBackgroundColor: lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: lightCardBorder, width: 1),
        ),
      ),

      // SnackBar Theme
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF212121),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: lightSubtleBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // FilledButton Theme
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),

      // OutlinedButton Theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: lightCardBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),

      dividerColor: lightCardBorder,
    );
  }
}

/// Standard AirBirr UI color constants and context-aware design system helpers.
class AppColors {
  static const Color accentCyan = AppTheme.darkPrimaryAccent;
  static const Color accentRed = AppTheme.darkSentRed;
  static const Color mintGreen = AppTheme.darkMintGreen;
  static const Color mutedYellow = AppTheme.darkMutedYellow;
  static const Color warmAmber = AppTheme.lightWarmAmber;
  static const Color error = AppTheme.darkError;
  static const Color mutedGray = AppTheme.mutedActionGray;

  /// Whether current theme context is in Dark Mode
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Card/Container Surface color
  static Color surface(BuildContext context) =>
      AppTheme.surfaceColor(Theme.of(context).brightness);

  /// Elevated Surface color for cards and chips
  static Color surfaceElevated(BuildContext context) =>
      isDark(context) ? AppTheme.darkSurfaceElevated : AppTheme.lightSurfaceElevated;

  /// High-elevated Surface color for floating panels/inputs
  static Color surfaceElevatedHigh(BuildContext context) =>
      isDark(context) ? AppTheme.darkSurfaceElevatedHigh : AppTheme.lightSurfaceElevatedHigh;

  /// Border color matching theme brightness
  static Color border(BuildContext context) =>
      AppTheme.borderColor(Theme.of(context).brightness);

  /// Subtle Border color
  static Color subtleBorder(BuildContext context) =>
      isDark(context) ? AppTheme.darkSubtleBorder : AppTheme.lightSubtleBorder;

  /// Primary high-contrast text color
  static Color textPrimary(BuildContext context) =>
      isDark(context) ? Colors.white : const Color(0xFF111827);

  /// Secondary muted text color
  static Color textSecondary(BuildContext context) =>
      isDark(context) ? const Color(0xFF9E9E9E) : const Color(0xFF6B7280);

  /// Tertiary placeholder/subtle text color
  static Color textTertiary(BuildContext context) =>
      isDark(context) ? const Color(0xFF616161) : const Color(0xFF9CA3AF);

  /// Mint green for credits and positive balances
  static Color mint(BuildContext context) =>
      AppTheme.onlineColor(Theme.of(context).brightness);

  /// Coral red for debits and sent payments
  static Color sent(BuildContext context) =>
      isDark(context) ? AppTheme.darkSentRed : AppTheme.lightSentRed;

  /// Primary cyan accent
  static Color accent(BuildContext context) =>
      AppTheme.accentColor(Theme.of(context).brightness);

  /// Offline indicator color (Muted Yellow in Dark, Warm Amber in Light)
  static Color offline(BuildContext context) =>
      AppTheme.offlineColor(Theme.of(context).brightness);
}
