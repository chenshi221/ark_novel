import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_prefs.dart';
import 'router.dart';
import 'security.dart';
import 'settings.dart';
import 'theme.dart';

class NextApp extends ConsumerWidget {
  const NextApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appPrefsProvider);
    return MaterialApp.router(
      title: 'Ark Novel',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, appPalettes[ref.watch(paletteProvider)]),
      darkTheme: buildAppTheme(Brightness.dark, appPalettes[ref.watch(paletteProvider)], AppPrefs.read(P.pureBlack, true)),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => AppGuard(child: child ?? const SizedBox.shrink()),
    );
  }
}
