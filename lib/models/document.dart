import 'dart:convert';
import 'dart:typed_data';

class ScannedDocument {
  const ScannedDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.imagePath,
    required this.text,
    this.imageBytes,
  });

  static const maxPersistedImageBytes = 2 * 1024 * 1024;

  final String id;
  final String name;
  final DateTime createdAt;
  final String imagePath;
  final String text;
  final Uint8List? imageBytes;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'imagePath': imagePath,
    'text': text,
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
      );
}
