import 'package:flutter/material.dart';

class ScanOverlay extends StatelessWidget {
  const ScanOverlay({super.key});

  // Adjust the inset, corner length, and stroke below to restyle the framing guide.
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth * .78;
          final height = constraints.maxHeight * .56;
          return SizedBox(
            width: width,
            height: height,
            child: CustomPaint(painter: _CornerFramePainter()),
          );
        },
      ),
    ),
  );
}

class _CornerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const length = 30.0;
    const stroke = 3.0;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    for (final point in <Offset>[
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      final xDirection = point.dx == 0 ? 1.0 : -1.0;
      final yDirection = point.dy == 0 ? 1.0 : -1.0;
      canvas.drawLine(point, point.translate(xDirection * length, 0), paint);
      canvas.drawLine(point, point.translate(0, yDirection * length), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
