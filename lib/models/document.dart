class ScannedDocument {
  const ScannedDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.imagePath,
    required this.text,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final String imagePath;
  final String text;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'imagePath': imagePath,
    'text': text,
  };

  factory ScannedDocument.fromJson(Map<String, dynamic> json) =>
      ScannedDocument(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        imagePath: json['imagePath'] as String,
        text: json['text'] as String? ?? '',
      );
}
