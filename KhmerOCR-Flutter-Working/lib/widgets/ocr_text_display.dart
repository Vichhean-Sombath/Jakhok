import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../theme.dart';

/// Displays OCR paragraphs as selectable text and recognized TeX as math.
class OcrTextDisplay extends StatelessWidget {
  const OcrTextDisplay({super.key, required this.text});

  final String text;

  static final _displayMath = RegExp(r'\\\[(.*?)\\\]', dotAll: true);
  static final _inlineMath = RegExp(r'\\\((.*?)\\\)', dotAll: true);

  @override
  Widget build(BuildContext context) {
    final segments = <Widget>[];
    var cursor = 0;

    for (final match in _displayMath.allMatches(text)) {
      if (match.start > cursor) {
        segments.add(
          _textSegment(context, text.substring(cursor, match.start)),
        );
      }

      final tex = match.group(1)?.trim() ?? '';
      if (tex.isNotEmpty) {
        segments.add(
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _math(context, tex, display: true),
              ),
            ),
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      segments.add(_textSegment(context, text.substring(cursor)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: segments,
    );
  }

  Widget _textSegment(BuildContext context, String value) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 16,
      height: 1.8,
      fontFamilyFallback: AppTheme.fontFallback,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _inlineMath.allMatches(value)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: value.substring(cursor, match.start)));
      }
      final tex = match.group(1)?.trim() ?? '';
      if (tex.isNotEmpty) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _math(context, tex, display: false),
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < value.length || spans.isEmpty) {
      spans.add(TextSpan(text: value.substring(cursor)));
    }

    return SelectableText.rich(TextSpan(style: style, children: spans));
  }

  Widget _math(BuildContext context, String tex, {required bool display}) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 16,
    );
    return Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      onErrorFallback: (_) => SelectableText(tex, style: style),
    );
  }
}
