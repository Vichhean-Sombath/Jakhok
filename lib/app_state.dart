import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/document.dart';

class AppState extends ChangeNotifier {
  static const _docsKey = 'scanned_documents_v1';
  static const _darkKey = 'dark_mode_v1';
  final List<ScannedDocument> documents = [];
  bool isDark = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    isDark = prefs.getBool(_darkKey) ?? false;
    final raw = prefs.getString(_docsKey);
    if (raw != null) {
      try {
        final rows = jsonDecode(raw) as List<dynamic>;
        documents
          ..clear()
          ..addAll(
            rows.map(
              (row) => ScannedDocument.fromJson(row as Map<String, dynamic>),
            ),
          );
        documents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } catch (_) {
        documents.clear();
      }
    }
  }

  Future<void> addDocument(ScannedDocument document) async {
    documents.insert(0, document);
    await _save();
    notifyListeners();
  }

  Future<void> deleteDocument(ScannedDocument document) async {
    documents.removeWhere((item) => item.id == document.id);
    await _save();
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    isDark = !isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, isDark);
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _docsKey,
      jsonEncode(documents.map((doc) => doc.toJson()).toList()),
    );
  }
}
