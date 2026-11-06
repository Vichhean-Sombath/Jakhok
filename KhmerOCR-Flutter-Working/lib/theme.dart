import 'package:flutter/material.dart';

class AppTheme {
  static const Color accent = Color(0xFF2F6BFF);
  static const Color lightBg = Color(0xFFF7F7F5);
  static const Color darkBg = Color(0xFF0E1218);
  static const Color primary = Color(0xFF1D2430);
  static const Color secondary = Color(0xFF667085);
  static const Color border = Color(0xFFE3E3DF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color darkSurface = Color(0xFF171D26);

  static const List<String> fontFallback = <String>['KhmerOSSiemReap'];

  static ThemeData get light => _make(Brightness.light);
  static ThemeData get dark => _make(Brightness.dark);

  static ThemeData _make(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final foreground = isDark ? const Color(0xFFF2F4F7) : primary;
    final muted = isDark ? const Color(0xFFA7B0BE) : secondary;
    final background = isDark ? darkBg : lightBg;
    final surface = isDark ? darkSurface : lightSurface;
    final outline = isDark ? const Color(0xFF303947) : border;
    final baseText = ThemeData(brightness: brightness).textTheme;
    final text = baseText
        .copyWith(
          headlineLarge: baseText.headlineLarge?.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -.8,
            height: 1.18,
          ),
          headlineMedium: baseText.headlineMedium?.copyWith(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -.6,
            height: 1.2,
          ),
          headlineSmall: baseText.headlineSmall?.copyWith(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            letterSpacing: -.4,
            height: 1.25,
          ),
          titleLarge: baseText.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -.2,
            height: 1.35,
          ),
          titleMedium: baseText.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
          bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 16, height: 1.55),
          bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
          bodySmall: baseText.bodySmall?.copyWith(fontSize: 12, height: 1.45),
          labelLarge: baseText.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        )
        .apply(
          bodyColor: foreground,
          displayColor: foreground,
          fontFamilyFallback: fontFallback,
        );

    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
          surface: background,
        ).copyWith(
          primary: accent,
          onPrimary: Colors.white,
          secondary: accent,
          onSecondary: Colors.white,
          surface: background,
          onSurface: foreground,
          surfaceContainerHighest: isDark
              ? const Color(0xFF222B38)
              : const Color(0xFFEEEFEC),
          onSurfaceVariant: muted,
          outline: outline,
          outlineVariant: isDark
              ? const Color(0xFF28313E)
              : const Color(0xFFEBEBE7),
          error: isDark ? const Color(0xFFFF8A80) : const Color(0xFFDC2626),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamilyFallback: fontFallback,
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      textTheme: text,
      primaryTextTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        titleTextStyle: text.titleMedium?.copyWith(fontSize: 17),
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: foreground, size: 22),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: Color(0x332F6BFF),
        selectionHandleColor: accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 14,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: muted),
        labelStyle: text.bodyMedium?.copyWith(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: accent.withValues(alpha: .38),
          disabledForegroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: surface,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? const Color(0xFF273140) : primary,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        textColor: foreground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      cardColor: surface,
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
