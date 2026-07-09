import 'package:flutter/material.dart';

import 'services/tv_mode.dart';

/// Dark, TV-friendly theme + centralized focus tokens (used by FocusableCard).
class AppTheme {
  static const bg = Color(0xFF0E1116);
  static const surface = Color(0xFF171C26);
  static const surfaceAlt = Color(0xFF141922);
  static const seed = Color(0xFF3E7BFA);
  static const focus = Color(0xFF7FA8FF);

  // Focus tokens — stronger on TV where the viewer sits meters away.
  static double get focusedScale => isTvMode ? 1.08 : 1.06;
  static double get focusRingWidth => isTvMode ? 4.0 : 3.0;

  /// 10-foot font ramp: bump a base size on TV.
  static double tvFont(double base, [double tvSize = 0]) =>
      isTvMode ? (tvSize > 0 ? tvSize : base + 3) : base;

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    // A focused control must be unmistakable from the couch: accent ring +
    // tinted fill. Material's default focus overlay (~10% white) is invisible
    // on our dark surfaces.
    final focusedSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: focus, width: 2.5)
          : null,
    );
    final focusedFill = WidgetStateProperty.resolveWith<Color?>(
      (states) => states.contains(WidgetState.focused)
          ? focus.withValues(alpha: 0.22)
          : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      // Visible D-pad focus on ink-based widgets (ListTile, IconButton …) —
      // the M3 default overlay is imperceptible on dark surfaces at 3 meters.
      focusColor: focus.withValues(alpha: 0.28),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceAlt,
        centerTitle: false,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceAlt,
        indicatorColor: seed.withValues(alpha: 0.25),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surfaceAlt,
        selectedIconTheme: const IconThemeData(color: focus),
        indicatorColor: const Color(0x333E7BFA),
        selectedLabelTextStyle: TextStyle(
          fontSize: isTvMode ? 15 : 13,
          color: focus,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: isTvMode ? 15 : 13,
          color: Colors.white70,
        ),
      ),
      cardColor: surface,
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        // Focused day-chips (Guide) get the accent ring.
        side: WidgetStateBorderSide.resolveWith((states) =>
            states.contains(WidgetState.focused)
                ? const BorderSide(color: focus, width: 2)
                : const BorderSide(color: Colors.transparent)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      // AppBar actions (refresh / reorder / visibility …) and dialog buttons —
      // these ignore ThemeData.focusColor, so style their focus explicitly.
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(side: focusedSide, backgroundColor: focusedFill),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(side: focusedSide, backgroundColor: focusedFill),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(side: focusedSide),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: focus, width: 2.5)
                : const BorderSide(color: Colors.white24),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        focusColor: focus.withValues(alpha: 0.4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceAlt,
        contentTextStyle: TextStyle(
          fontSize: isTvMode ? 17 : 15,
          color: Colors.white,
        ),
        insetPadding: EdgeInsets.only(
          left: 64,
          right: 64,
          bottom: isTvMode ? 64 : 24,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      visualDensity: VisualDensity.comfortable,
    );
  }
}
