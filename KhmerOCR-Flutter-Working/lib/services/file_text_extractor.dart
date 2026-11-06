import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Extracts text from common document formats. Image OCR remains platform-specific.
class FileTextExtractor {
  static Future<String> extract(String filename, List<int> bytes) async {
    final extension = filename.split('.').last.toLowerCase();
    if (extension == 'pdf' || _hasPdfSignature(bytes)) {
      return (await extractPdfPages(bytes))
          .where((text) => text.isNotEmpty)
          .join('\n\n');
    }
    if (const {
      'txt',
      'text',
      'md',
      'markdown',
      'csv',
      'tsv',
      'jsonl',
      'ndjson',
      'json',
      'xml',
      'xhtml',
      'svg',
      'html',
      'htm',
      'log',
      'ini',
      'yaml',
      'yml',
      'conf',
      'properties',
      'toml',
      'sql',
      'srt',
      'vtt',
      'ass',
      'ssa',
      'ics',
      'eml',
      'tex',
      'rst',
      'org',
      'adoc',
      'dart',
      'py',
      'js',
      'ts',
      'css',
      'scss',
      'java',
      'kt',
      'c',
      'h',
      'cpp',
      'hpp',
      'cs',
      'go',
      'rs',
      'php',
      'rb',
      'swift',
      'm',
      'gradle',
      'sh',
      'bat',
      'ps1',
      'dockerfile',
    }.contains(extension)) {
      var text = _decode(bytes).trim();
      if (const {'html', 'htm', 'xhtml', 'svg', 'srt', 'vtt', 'ass', 'ssa'}
          .contains(extension)) {
        text = text
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(
                RegExp(r'^\s*(?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}.*$',
                    multiLine: true),
                ' ')
            .replaceAll(RegExp(r'^\s*\d+\s*$', multiLine: true), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      return text;
    }
    if (const {
      'docx',
      'docm',
      'dotx',
      'dotm',
      'xlsx',
      'xlsm',
      'xltx',
      'xltm',
      'pptx',
      'pptm',
      'ppsx',
      'potx',
      'potm',
      'odt',
      'ods',
      'odp',
      'epub',
    }.contains(extension)) {
      return _extractOffice(extension, bytes);
    }
    if (const {'fodt', 'fods', 'fodp'}.contains(extension)) {
      return _unescapeXml(_decode(bytes).replaceAll(RegExp(r'<[^>]+>'), ' '))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    if (extension == 'zip' || _hasZipSignature(bytes))
      return _extractZip(bytes);
    if (extension == 'rtf') {
      return _decode(bytes)
          .replaceAll(RegExp(r"\\'[0-9a-fA-F]{2}"), ' ')
          .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), ' ')
          .replaceAll(RegExp(r'[{}]'), ' ')
          .trim();
    }
    final guessedText = _decode(bytes).trim();
    if (_isMostlyText(guessedText)) return guessedText;
    throw UnsupportedError(
        'Text extraction is not available for .$extension files.');
  }

  static bool _hasPdfSignature(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x25 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x46;

  static bool _hasZipSignature(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      const {
        0x03,
        0x05,
        0x07,
      }.contains(bytes[2]) &&
      const {
        0x04,
        0x06,
        0x08,
      }.contains(bytes[3]);

  static bool _isMostlyText(String text) {
    if (text.isEmpty || text.codeUnits.contains(0)) return false;
    final visible = text.codeUnits
        .where((unit) => unit == 9 || unit == 10 || unit == 13 || unit >= 32)
        .length;
    return visible / text.length >= .9;
  }

  static Future<List<String>> extractPdfPages(List<int> bytes) async {
    final pdf = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(pdf);
      return List.generate(
        pdf.pages.count,
        (index) => extractor
            .extractText(startPageIndex: index, endPageIndex: index)
            .trim(),
      );
    } finally {
      pdf.dispose();
    }
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static String _extractOffice(String extension, List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final xmlFiles = archive.files
        .where((file) => file.isFile && file.name.endsWith('.xml'));
    if (const {'xlsx', 'xlsm', 'xltx', 'xltm'}.contains(extension)) {
      return _extractSpreadsheet(archive, xmlFiles);
    }
    final selected = switch (extension) {
      'docx' ||
      'docm' ||
      'dotx' ||
      'dotm' =>
        xmlFiles.where((file) => file.name == 'word/document.xml'),
      'epub' => archive.files.where((file) =>
          file.isFile &&
          RegExp(r'\.(?:xhtml|html?|xml)$', caseSensitive: false)
              .hasMatch(file.name)),
      'pptx' || 'pptm' || 'ppsx' || 'potx' || 'potm' => xmlFiles.where(
          (file) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(file.name)),
      _ => xmlFiles.where((file) => file.name.endsWith('content.xml')),
    };
    final chunks = <String>[];
    for (final file in selected) {
      final xml = _decode(file.content as List<int>);
      final withBreaks = xml.replaceAll(
          RegExp(r'</(?:w:p|a:p|table:table-row|text:p)>'), '\n');
      final plain = withBreaks.replaceAll(RegExp(r'<[^>]+>'), ' ');
      chunks.add(_unescapeXml(plain));
    }
    return chunks.join('\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  static Future<String> _extractZip(List<int> bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    const readableExtensions = {
      'txt',
      'text',
      'md',
      'markdown',
      'csv',
      'tsv',
      'json',
      'xml',
      'html',
      'htm',
      'log',
      'ini',
      'yaml',
      'yml',
      'rtf',
      'pdf',
      'docx',
      'docm',
      'dotx',
      'dotm',
      'xlsx',
      'xlsm',
      'xltx',
      'xltm',
      'pptx',
      'pptm',
      'ppsx',
      'potx',
      'potm',
      'odt',
      'ods',
      'odp',
      'epub',
      'srt',
      'vtt',
      'eml',
    };
    final parts = <String>[];
    var extractedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile || file.size > 20 * 1024 * 1024) continue;
      final extension = file.name.split('.').last.toLowerCase();
      if (!readableExtensions.contains(extension)) continue;
      extractedBytes += file.size;
      if (extractedBytes > 100 * 1024 * 1024) break;
      try {
        final text = await extract(file.name, file.content as List<int>);
        if (text.trim().isNotEmpty) parts.add('--- ${file.name} ---\n$text');
      } on UnsupportedError {
        continue;
      }
    }
    return parts.join('\n\n');
  }

  static String _extractSpreadsheet(
    Archive archive,
    Iterable<ArchiveFile> xmlFiles,
  ) {
    final sharedFile = archive.files
        .where((file) => file.isFile && file.name == 'xl/sharedStrings.xml')
        .firstOrNull;
    final sharedStrings = sharedFile == null
        ? <String>[]
        : RegExp(r'<si(?:\s[^>]*)?>(.*?)</si>', dotAll: true)
            .allMatches(_decode(sharedFile.content as List<int>))
            .map((match) => _unescapeXml(match
                .group(1)!
                .replaceAll(RegExp(r'<[^>]+>'), ' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim()))
            .toList();
    final sheets =
        xmlFiles.where((file) => file.name.startsWith('xl/worksheets/'));
    final rows = <String>[];
    for (final sheet in sheets) {
      final xml = _decode(sheet.content as List<int>);
      for (final row in RegExp(r'<row(?:\s[^>]*)?>(.*?)</row>', dotAll: true)
          .allMatches(xml)) {
        final cells = <String>[];
        for (final cell in RegExp(r'<c(?:\s[^>]*)?>(.*?)</c>', dotAll: true)
            .allMatches(row.group(1)!)) {
          final value = RegExp(r'<v>(.*?)</v>', dotAll: true)
              .firstMatch(cell.group(1)!)
              ?.group(1);
          if (value == null) {
            cells.add('');
          } else if (RegExp(r'\bt="s"').hasMatch(cell.group(0)!)) {
            final index = int.tryParse(value);
            cells.add(index != null && index < sharedStrings.length
                ? sharedStrings[index]
                : '');
          } else {
            cells.add(_unescapeXml(value));
          }
        }
        if (cells.any((cell) => cell.isNotEmpty)) rows.add(cells.join('\t'));
      }
      rows.add('');
    }
    return rows.join('\n').trim();
  }

  static String _unescapeXml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}
