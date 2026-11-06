import 'dart:convert';
import 'dart:typed_data';

import 'image_detection.dart';

class ScannedDocument {
  const ScannedDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.imagePath,
    required this.text,
    this.imageBytes,
    this.imageSize,
    this.detectionBoxes = const [],
    this.detectionError,
  });

  static const maxPersistedImageBytes = 2 * 1024 * 1024;

  final String id;
  final String name;
  final DateTime createdAt;
  final String imagePath;
  final String text;
  final Uint8List? imageBytes;
  final ImageSize? imageSize;
  final List<DetectedTextBox> detectionBoxes;
  final String? detectionError;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'imagePath': imagePath,
    'text': text,
    'imageSize': imageSize?.toJson(),
    'detectionBoxes': detectionBoxes.map((box) => box.toJson()).toList(),
    'detectionError': detectionError,
    'imageData': imageBytes == null ||
            imageBytes!.lengthInBytes > maxPersistedImageBytes
        ? null
        : base64Encode(imageBytes!),
  };

  factory ScannedDocument.fromJson(Map<String, dynamic> json) =>
      ScannedDocument(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        imagePath: json['imagePath'] as String,
        text: json['text'] as String? ?? '',
        imageBytes: json['imageData'] is String
            ? Uint8List.fromList(base64Decode(json['imageData'] as String))
            : null,
        imageSize: json['imageSize'] is Map
            ? ImageSize.fromJson(json['imageSize'])
            : null,
        detectionBoxes: _readDetectionBoxes(json['detectionBoxes']),
        detectionError: json['detectionError'] as String?,
      );
}

List<DetectedTextBox> _readDetectionBoxes(Object? value) {
  if (value is! List) return const [];
  final boxes = <DetectedTextBox>[];
  for (final row in value) {
    if (row is! Map) continue;
    try {
      boxes.add(DetectedTextBox.fromJson(row));
    } on FormatException {
      continue;
    }
  }
  return boxes;
}
