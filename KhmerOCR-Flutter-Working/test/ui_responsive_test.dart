import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:khmer_ocr_flutter/app_state.dart';
import 'package:khmer_ocr_flutter/models/document.dart';
import 'package:khmer_ocr_flutter/screens/chat_screen.dart';
import 'package:khmer_ocr_flutter/screens/detail_screen.dart';
import 'package:khmer_ocr_flutter/screens/home_screen.dart';
import 'package:khmer_ocr_flutter/screens/scan_screen.dart';
import 'package:khmer_ocr_flutter/screens/settings_screen.dart';
import 'package:khmer_ocr_flutter/screens/sign_in_screen.dart';
import 'package:khmer_ocr_flutter/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ScannedDocument sampleDocument() => ScannedDocument(
    id: 'khmer-document',
    name: 'ឯកសារ សួស្តី.pdf',
    createdAt: DateTime(2026, 11, 7),
    imagePath: '',
    text: 'សួស្តី ពិភពលោក\n\nNetra keeps Khmer text readable.',
  );

  Future<AppState> makeState({bool withDocument = true}) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await state.load();
    if (withDocument) state.documents.add(sampleDocument());
    return state;
  }

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  test('light and dark themes retain Khmer font fallback', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      expect(
        theme.textTheme.bodyMedium?.fontFamilyFallback,
        contains('KhmerOSSiemReap'),
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, isNot('KhmerOSSiemReap'));
    }
    expect(
      AppTheme.light.scaffoldBackgroundColor,
      isNot(AppTheme.light.cardColor),
    );
    expect(
      AppTheme.dark.scaffoldBackgroundColor,
      isNot(AppTheme.dark.cardColor),
    );
  });

  testWidgets('sign-in adapts from desktop introduction to mobile card', (
    tester,
  ) async {
    await setSize(tester, const Size(1280, 900));
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const SignInScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Netra'), findsOneWidget);
    expect(find.text('Every document,\nreadable.'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark, home: const SignInScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Every document,\nreadable.'), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sidebar opens documents and settings', (tester) async {
    final state = await makeState();
    await setSize(tester, const Size(1440, 900));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(state: state, authService: null, user: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Upload a document'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);

    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.text('ឯកសារ សួស្តី.pdf'), findsOneWidget);
    expect(find.text('1 saved document · newest first'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Preferences'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile drawer opens document history without overflow', (
    tester,
  ) async {
    final state = await makeState();
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(state: state, authService: null, user: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open navigation'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.text('ឯកសារ សួស្តី.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document details keep Khmer text readable at both widths', (
    tester,
  ) async {
    final state = await makeState();
    for (final size in [const Size(390, 844), const Size(1440, 900)]) {
      await tester.pumpWidget(const SizedBox());
      await setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: DetailScreen(document: sampleDocument(), state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Extracted text'), findsOneWidget);
      expect(
        find.textContaining(
          'Netra keeps Khmer text readable.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Chat with this Document'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('document chat suggestions fit a mobile viewport', (
    tester,
  ) async {
    final state = await makeState();
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ChatScreen(document: sampleDocument(), state: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Document chat'), findsOneWidget);
    expect(find.text('Ask anything about your document'), findsOneWidget);
    expect(find.text('Summarize this document'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings toggle preserves theme behavior on mobile', (
    tester,
  ) async {
    final state = await makeState();
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: SettingsScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('About Netra'), findsOneWidget);
    expect(state.isDark, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(state.isDark, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scanner fallback remains usable when camera is unavailable', (
    tester,
  ) async {
    final state = await makeState(withDocument: false);
    const permissionChannel = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      permissionChannel,
      (call) async =>
          call.method == 'requestPermissions' ? <int, int>{1: 0} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissionChannel,
        null,
      ),
    );
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ScanScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    if (find.text('Not now').evaluate().isNotEmpty) {
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Camera not available'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.byTooltip('Choose a document'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
