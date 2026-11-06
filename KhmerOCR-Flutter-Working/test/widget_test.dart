import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:khmer_ocr_flutter/main.dart';
import 'package:khmer_ocr_flutter/app_state.dart';
import 'package:khmer_ocr_flutter/models/document.dart';

void main() {
  testWidgets('signed-out app shows Google sign-in and keeps Khmer documents', (
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
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
