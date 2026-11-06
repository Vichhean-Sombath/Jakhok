import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/document.dart';
import 'models/image_detection.dart';
import 'services/ocr_api_client.dart';

enum BackgroundOcrStatus { preparing, running, complete, failed }

class BackgroundOcrJob {
  BackgroundOcrJob({
    required this.name,
    required this.imageBytes,
    required this.imageSize,
    required this.detectionBoxes,
    required this.selectedRegionIds,
    required this.options,
  });

  final String name;
  final Uint8List imageBytes;
  final ImageSize? imageSize;
  final List<DetectedTextBox> detectionBoxes;
  final List<String>? selectedRegionIds;
  final OcrRecognitionOptions options;
  BackgroundOcrStatus status = BackgroundOcrStatus.preparing;
  String progressText = 'Preparing OCR…';
  int currentRegion = 0;
  int totalRegions = 0;
  String? error;
  ScannedDocument? document;
}

class AppState extends ChangeNotifier {
  static const _docsKey = 'scanned_documents_v1';
  static const _generalChatsKey = 'general_chat_sessions_v1';
  static const _darkKey = 'dark_mode_v1';
  static String chatHistoryKey(String documentId) => 'chat_history_$documentId';
  final List<ScannedDocument> documents = [];
  final List<GeneralChatSession> generalChatHistory = [];
  final Set<String> _chatHistoryDocumentIds = {};
  BackgroundOcrJob? backgroundOcrJob;
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

  BackgroundOcrJob startBackgroundOcr({
    required String name,
    required Uint8List imageBytes,
    required ImageDetectionResult? detection,
    required List<String>? selectedRegionIds,
    required OcrRecognitionOptions options,
  }) {
    if (backgroundOcrJob?.status == BackgroundOcrStatus.preparing ||
        backgroundOcrJob?.status == BackgroundOcrStatus.running) {
      throw StateError('An OCR scan is already running.');
    }
    final job = BackgroundOcrJob(
      name: name,
      imageBytes: imageBytes,
      imageSize: detection?.imageSize,
      detectionBoxes: detection?.boxes ?? const [],
      selectedRegionIds: selectedRegionIds == null
          ? null
          : List.unmodifiable(selectedRegionIds),
      options: options,
    );
    backgroundOcrJob = job;
    notifyListeners();
    unawaited(_runBackgroundOcr(job));
    return job;
  }

  Future<void> _runBackgroundOcr(BackgroundOcrJob job) async {
    final client = OcrApiClient();
    try {
      await client.ensureReady();
      job
        ..status = BackgroundOcrStatus.running
        ..progressText = job.options.streamResults
            ? 'Detecting selected regions…'
            : 'Recognizing selected regions…';
      notifyListeners();
      final result = await client.recognizeImageWithOptions(
        job.imageBytes,
        filename: job.name,
        options: job.options,
        selectedRegionIds: job.selectedRegionIds,
        onRegionProgress: (current, total) {
          job
            ..currentRegion = current
            ..totalRegions = total
            ..progressText = 'Reading region $current of $total…';
          notifyListeners();
        },
      );
      if (result.text.isEmpty) {
        throw const OcrException('No text was found in the selected regions.');
      }
      final now = DateTime.now();
      final document = ScannedDocument(
        id: '${now.microsecondsSinceEpoch}',
        name: job.name,
        createdAt: now,
        imagePath: '',
        text: result.text,
        imageBytes: job.imageBytes,
        imageSize: result.imageSize ?? job.imageSize,
        detectionBoxes: job.detectionBoxes,
      );
      await addDocument(document);
      job
        ..document = document
        ..status = BackgroundOcrStatus.complete
        ..progressText = 'Scan complete';
      notifyListeners();
    } catch (error) {
      job
        ..status = BackgroundOcrStatus.failed
        ..error = error is OcrException
            ? error.message
            : 'Could not finish this scan. Check your connection and try again.'
        ..progressText = 'Scan failed';
      notifyListeners();
    } finally {
      client.close();
    }
  }

  void dismissBackgroundOcrJob() {
    final job = backgroundOcrJob;
    if (job == null ||
        job.status == BackgroundOcrStatus.preparing ||
        job.status == BackgroundOcrStatus.running) {
      return;
    }
    backgroundOcrJob = null;
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
