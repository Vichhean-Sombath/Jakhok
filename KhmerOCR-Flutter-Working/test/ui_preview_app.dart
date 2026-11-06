import 'package:flutter/material.dart';

import 'package:khmer_ocr_flutter/app_state.dart';
import 'package:khmer_ocr_flutter/models/document.dart';
import 'package:khmer_ocr_flutter/screens/home_screen.dart';
import 'package:khmer_ocr_flutter/screens/chat_screen.dart';
import 'package:khmer_ocr_flutter/screens/detail_screen.dart';
import 'package:khmer_ocr_flutter/screens/settings_screen.dart';
import 'package:khmer_ocr_flutter/screens/sign_in_screen.dart';
import 'package:khmer_ocr_flutter/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  if (state.documents.isEmpty) {
    state.documents.addAll([
      ScannedDocument(
        id: 'preview-khmer',
        name: 'ឯកសារ សួស្តី.pdf',
        createdAt: DateTime(2026, 11, 7, 9, 30),
        imagePath: '',
        text:
            'សួស្តី ពិភពលោក\n\n'
            'Netra keeps Khmer text readable alongside English. '
            'Select, copy, download, or discuss the extracted text.',
      ),
      ScannedDocument(
        id: 'preview-notes',
        name: 'Meeting notes.txt',
        createdAt: DateTime(2026, 11, 6, 16, 45),
        imagePath: '',
        text: 'Document history and local preview content.',
      ),
    ]);
  }
  runApp(NetraPreviewApp(state: state));
}

class NetraPreviewApp extends StatelessWidget {
  const NetraPreviewApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        title: 'Netra UI Preview',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: state.isDark ? ThemeMode.dark : ThemeMode.light,
        initialRoute: '/workspace',
        routes: {
          '/signin': (_) => const SignInScreen(),
          '/detail': (_) =>
              DetailScreen(document: state.documents.first, state: state),
          '/chat': (_) =>
              ChatScreen(document: state.documents.first, state: state),
          '/settings': (_) => SettingsScreen(state: state),
          '/workspace': (_) =>
              HomeScreen(state: state, authService: null, user: null),
        },
      ),
    );
  }
}
