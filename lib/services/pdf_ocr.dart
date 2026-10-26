import 'ocr_api_client.dart';

/// Retains text layers and OCRs only missing pages, in document order.
Future<String> fillMissingPdfText({
  required List<String> pageTexts,
  required Future<List<int>> Function(int pageNumber) renderPage,
  required Future<String> Function(List<int> bytes) recognize,
  required bool Function() isActive,
  void Function(int pageNumber, int total)? onProgress,
}) async {
  final result = List<String>.of(pageTexts);
  for (var index = 0; index < result.length; index++) {
    if (!isActive()) throw const OcrException('Scan cancelled.');
    if (result[index].trim().isNotEmpty) continue;
    onProgress?.call(index + 1, result.length);
    final bytes = await renderPage(index + 1);
    if (!isActive()) throw const OcrException('Scan cancelled.');
    result[index] = await recognize(bytes);
  }
  return result.join('\n\n');
}
