import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gère le mode clair / sombre / système et le mémorise entre les lancements.
class ThemeService {
  ThemeService._();

  static final ThemeService instance = ThemeService._();

  static const _key = 'theme_mode';

  final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = _fromString(prefs.getString(_key));
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }

  /// Alterne système -> clair -> sombre -> système.
  Future<void> cycle() async {
    final next = switch (mode.value) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    await set(next);
  }

  IconData get icon => switch (mode.value) {
        ThemeMode.system => Icons.brightness_auto,
        ThemeMode.light => Icons.light_mode,
        ThemeMode.dark => Icons.dark_mode,
      };

  String get label => switch (mode.value) {
        ThemeMode.system => 'Thème : système',
        ThemeMode.light => 'Thème : clair',
        ThemeMode.dark => 'Thème : sombre',
      };

  static ThemeMode _fromString(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
