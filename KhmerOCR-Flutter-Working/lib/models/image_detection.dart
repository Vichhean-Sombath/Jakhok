class ImageSize {
  const ImageSize({required this.width, required this.height});

  final double width;
  final double height;

  factory ImageSize.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Missing image size.');
    final width = _readFiniteNumber(value['width']);
    final height = _readFiniteNumber(value['height']);
    if (width <= 0 || height <= 0) {
      throw const FormatException('Invalid image size.');
    }
    return ImageSize(width: width, height: height);
  }

  Map<String, Object> toJson() => {'width': width, 'height': height};
}

class DetectedTextBox {
  const DetectedTextBox({
    required this.id,
    required this.label,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String id;
  final String label;
  final double left;
  final double top;
  final double right;
  final double bottom;

  factory DetectedTextBox.fromJson(Map value) {
    final bbox = value['bbox'];
    if (bbox is! List || bbox.length != 4) {
      throw const FormatException('Invalid detection box.');
    }
    final left = _readFiniteNumber(bbox[0]);
    final top = _readFiniteNumber(bbox[1]);
    final right = _readFiniteNumber(bbox[2]);
    final bottom = _readFiniteNumber(bbox[3]);
    if (right <= left || bottom <= top) {
      throw const FormatException('Invalid detection box bounds.');
    }
    final rawId = value['id'];
    final rawLabel = value['label'];
    return DetectedTextBox(
      id: rawId?.toString() ?? '',
      label: rawLabel is String ? rawLabel : '',
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'label': label,
    'bbox': [left, top, right, bottom],
  };
}

class ImageDetectionResult {
  const ImageDetectionResult({required this.imageSize, required this.boxes});

  final ImageSize imageSize;
  final List<DetectedTextBox> boxes;

  factory ImageDetectionResult.fromJson(Map<String, dynamic> json) {
    final imageSize = ImageSize.fromJson(json['image_size']);
    final rawBoxes = json['boxes'];
    if (rawBoxes is! List) {
      throw const FormatException('Missing detection boxes.');
    }
    final boxes = <DetectedTextBox>[];
    for (final value in rawBoxes) {
      if (value is! Map) continue;
      try {
        boxes.add(DetectedTextBox.fromJson(value));
      } on FormatException {
        continue;
      }
    }
    if (rawBoxes.isNotEmpty && boxes.isEmpty) {
      throw const FormatException('Invalid detection boxes.');
    }
    return ImageDetectionResult(imageSize: imageSize, boxes: boxes);
  }
}

double _readFiniteNumber(Object? value) {
  if (value is! num) throw const FormatException('Expected a number.');
  final result = value.toDouble();
  if (!result.isFinite) throw const FormatException('Expected a finite number.');
  return result;
}
