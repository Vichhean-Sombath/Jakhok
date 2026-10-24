import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/document.dart';
import 'theme.dart';

class AppState extends ChangeNotifier {
  static const _docsKey = 'scanned_documents_v1';
  static const _generalChatsKey = 'general_chat_sessions_v1';
  static const _darkKey = 'dark_mode_v1';
  static const _accentKey = 'accent_color_v1';
  static String chatHistoryKey(String documentId) => 'chat_history_$documentId';
  final List<ScannedDocument> documents = [];
  final List<GeneralChatSession> generalChatHistory = [];
  final Set<String> _chatHistoryDocumentIds = {};
  bool isDark = false;

  List<ScannedDocument> get chatHistory => documents
      .where((document) => _chatHistoryDocumentIds.contains(document.id))
      .toList(growable: false);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    isDark = prefs.getBool(_darkKey) ?? false;
    AppTheme.accent = Color(
      prefs.getInt(_accentKey) ?? const Color(0xFF3563F5).value,
    );
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
    final rawChats = prefs.getString(_generalChatsKey);
    if (rawChats != null) {
      try {
        final rows = jsonDecode(rawChats) as List<dynamic>;
        generalChatHistory
          ..clear()
          ..addAll(
            rows.map(
              (row) => GeneralChatSession.fromJson(row as Map<String, dynamic>),
            ),
          )
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } catch (_) {
        generalChatHistory.clear();
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

  Future<void> saveGeneralChat(String id, String title) async {
    generalChatHistory.removeWhere((chat) => chat.id == id);
    generalChatHistory.insert(
      0,
      GeneralChatSession(id: id, title: title, updatedAt: DateTime.now()),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _generalChatsKey,
      jsonEncode(generalChatHistory.map((chat) => chat.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    isDark = !isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, isDark);
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    isDark = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, isDark);
    notifyListeners();
  }

  Future<void> setAccentColor(Color value) async {
    AppTheme.accent = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentKey, value.value);
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

class GeneralChatSession {
  const GeneralChatSession({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory GeneralChatSession.fromJson(Map<String, dynamic> json) =>
      GeneralChatSession(
        id: json['id'] as String,
        title: json['title'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}
