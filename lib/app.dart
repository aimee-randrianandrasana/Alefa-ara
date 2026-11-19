import 'package:material_ui/material_ui.dart';

import 'screens/home_screen.dart';
import 'services/theme_service.dart';

class AlefaAraApp extends StatelessWidget {
  const AlefaAraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeService.instance.mode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Alefa arà',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF4F64E8),
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF4F64E8),
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          themeMode: themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }
}
