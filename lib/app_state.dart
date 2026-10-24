import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/document.dart';

class AppState extends ChangeNotifier {
  static const _docsKey = 'scanned_documents_v1';
  static const _darkKey = 'dark_mode_v1';
  static String chatHistoryKey(String documentId) => 'chat_history_$documentId';
  final List<ScannedDocument> documents = [];
  final Set<String> _chatHistoryDocumentIds = {};
  bool isDark = false;

  List<ScannedDocument> get chatHistory => documents
      .where((document) => _chatHistoryDocumentIds.contains(document.id))
      .toList(growable: false);

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
    _chatHistoryDocumentIds
      ..clear()
      ..addAll(
        documents
            .where((document) {
              final history = prefs.getString(chatHistoryKey(document.id));
              if (history == null) return false;
              try {
                return (jsonDecode(history) as List<dynamic>).any(
                  (row) => row is Map && row['isUser'] == true,
                );
              } catch (_) {
                return false;
              }
            })
            .map((document) => document.id),
      );
  }

  Future<void> addDocument(ScannedDocument document) async {
    documents.insert(0, document);
    await _save();
    notifyListeners();
  }

  Future<void> deleteDocument(ScannedDocument document) async {
    documents.removeWhere((item) => item.id == document.id);
    _chatHistoryDocumentIds.remove(document.id);
    await _save();
    notifyListeners();
  }

  void markChatHistory(String documentId) {
    if (_chatHistoryDocumentIds.add(documentId)) notifyListeners();
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
