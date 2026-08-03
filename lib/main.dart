import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/flash_home_page.dart';

void main() {
  runApp(const ProviderScope(child: EspflashApp()));
}

class EspflashApp extends StatelessWidget {
  const EspflashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'espflash',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: const FlashHomePage(),
    );
  }
}
