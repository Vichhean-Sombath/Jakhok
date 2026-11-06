import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/image_detection.dart';

/// Displays an image with its server-coordinate detection boxes overlaid.
class DetectionImageView extends StatelessWidget {
  const DetectionImageView({
    super.key,
    required this.imageProvider,
    this.imageSize,
    this.boxes = const [],
    this.selectedBoxIds,
    this.onBoxTap,
    this.backgroundColor = Colors.black,
  });

  final ImageProvider<Object> imageProvider;
  final ImageSize? imageSize;
  final List<DetectedTextBox> boxes;
  final Set<String>? selectedBoxIds;
  final ValueChanged<String>? onBoxTap;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: backgroundColor,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onBoxTap == null || imageSize == null
              ? null
              : (details) {
                  final id = _hitBox(details.localPosition, canvasSize);
                  if (id != null) onBoxTap!(id);
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(image: imageProvider, fit: BoxFit.contain),
              if (imageSize != null && boxes.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: DetectionBoxPainter(
                      imageSize: imageSize!,
                      boxes: boxes,
                      selectedBoxIds: selectedBoxIds,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );

  String? _hitBox(Offset point, Size size) {
    final source = imageSize;
    if (source == null || size.isEmpty) return null;
    final scale = math.min(
      size.width / source.width,
      size.height / source.height,
    );
    final imageRect = Rect.fromLTWH(
      (size.width - source.width * scale) / 2,
      (size.height - source.height * scale) / 2,
      source.width * scale,
      source.height * scale,
    );
    for (final box in boxes.reversed) {
      final rect = Rect.fromLTRB(
        imageRect.left + box.left.clamp(0, source.width).toDouble() * scale,
        imageRect.top + box.top.clamp(0, source.height).toDouble() * scale,
        imageRect.left + box.right.clamp(0, source.width).toDouble() * scale,
        imageRect.top + box.bottom.clamp(0, source.height).toDouble() * scale,
      );
      if (rect.contains(point)) return box.id;
    }
    return null;
  }
}

class DetectionBoxPainter extends CustomPainter {
  const DetectionBoxPainter({
    required this.imageSize,
    required this.boxes,
    this.selectedBoxIds,
  });

  final ImageSize imageSize;
  final List<DetectedTextBox> boxes;
  final Set<String>? selectedBoxIds;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || imageSize.width <= 0 || imageSize.height <= 0) return;

    final scale = math.min(
      size.width / imageSize.width,
      size.height / imageSize.height,
    );
    final fittedWidth = imageSize.width * scale;
    final fittedHeight = imageSize.height * scale;
    final imageRect = Rect.fromLTWH(
      (size.width - fittedWidth) / 2,
      (size.height - fittedHeight) / 2,
      fittedWidth,
      fittedHeight,
    );
    canvas.save();
    canvas.clipRect(imageRect);
    for (var index = 0; index < boxes.length; index++) {
      final box = boxes[index];
      final left = box.left.clamp(0.0, imageSize.width).toDouble();
      final top = box.top.clamp(0.0, imageSize.height).toDouble();
      final right = box.right.clamp(0.0, imageSize.width).toDouble();
      final bottom = box.bottom.clamp(0.0, imageSize.height).toDouble();
      if (right <= left || bottom <= top) continue;

      final rect = Rect.fromLTRB(
        imageRect.left + left * scale,
        imageRect.top + top * scale,
        imageRect.left + right * scale,
        imageRect.top + bottom * scale,
      );
      final selected =
          selectedBoxIds == null || selectedBoxIds!.contains(box.id);
      final outline = Paint()
        ..color = selected ? const Color(0xFF5EE6A8) : const Color(0xFFFFA66B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.4 : 2.0;
      final fill = Paint()
        ..color = selected ? const Color(0x285EE6A8) : const Color(0x20FFA66B)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, outline);
      final label = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = Rect.fromLTWH(
        rect.left,
        math.max(imageRect.top, rect.top - 14),
        label.width + 8,
        14,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge, const Radius.circular(3)),
        Paint()
          ..color = selected
              ? const Color(0xFF16885D)
              : const Color(0xFF9A4D1E),
      );
      label.paint(canvas, Offset(badge.left + 4, badge.top + 1));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DetectionBoxPainter oldDelegate) =>
      oldDelegate.imageSize.width != imageSize.width ||
      oldDelegate.imageSize.height != imageSize.height ||
      oldDelegate.boxes != boxes ||
      oldDelegate.selectedBoxIds != selectedBoxIds;
}
