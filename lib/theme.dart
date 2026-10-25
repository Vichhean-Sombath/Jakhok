import 'package:flutter/material.dart';

class AppTheme {
  // Change this single token to update active chips and selection accents.
  static Color accent = const Color(0xFF3563F5);
  static const lightBg = Color(0xFFFFFFFF);
  static const darkBg = Color(0xFF1A1A1A);
  static const primary = Color(0xFF1F1F1F);
  static const secondary = Color(0xFF8E8E8E);
  static const border = Color(0xFFE5E5E5);

  static ThemeData get light => _make(Brightness.light);
  static ThemeData get dark => _make(Brightness.dark);

  static ThemeData _make(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final fg = dark ? Colors.white : primary;
    final bg = dark ? darkBg : lightBg;
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'KhmerOSSiemReap',
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: bg,
        primary: dark ? Colors.white : Colors.black,
        onPrimary: dark ? Colors.black : Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: fg,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerColor: dark ? const Color(0xFF333333) : border,
      iconTheme: IconThemeData(color: fg),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.white,
      ),
      textTheme: ThemeData(
        brightness: brightness,
      ).textTheme.apply(
        bodyColor: fg,
        displayColor: fg,
        fontFamily: 'KhmerOSSiemReap',
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: dark ? Colors.white : Colors.black,
        foregroundColor: dark ? Colors.black : Colors.white,
        elevation: 0,
      ),
    );
  }
}
