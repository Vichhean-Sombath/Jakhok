import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:khmer_ocr_flutter/main.dart';
import 'package:khmer_ocr_flutter/app_state.dart';
import 'package:khmer_ocr_flutter/models/document.dart';
import 'package:khmer_ocr_flutter/screens/home_screen.dart';
import 'package:khmer_ocr_flutter/screens/settings_screen.dart';

void main() {
  testWidgets('existing app starts and preserves saved Khmer documents', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await state.load();
    await state.addDocument(
      ScannedDocument(
        id: 'test',
        name: 'Khmer scan',
        createdAt: DateTime(2026),
        imagePath: '',
        text: 'សួស្តី',
      ),
    );
    final restored = AppState();
    await restored.load();
    expect(restored.documents.single.text, 'សួស្តី');
    await tester.pumpWidget(ScannerApp(state: restored));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setting'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
