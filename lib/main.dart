import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/app_theme.dart';
import 'ui/flash_home_page.dart';

void main() {
  runApp(const ProviderScope(child: EspflashApp()));
}

class EspflashApp extends StatelessWidget {
  const EspflashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP Flash',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const FlashHomePage(),
    );
  }
}
