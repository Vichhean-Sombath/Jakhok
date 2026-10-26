import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class OcrException implements Exception {
  const OcrException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Adapter for the existing Python API. Inference options are owned by the server.
class OcrApiClient {
  OcrApiClient({
    http.Client? client,
    String? baseUrl,
    Duration? statusTimeout,
    Duration? ocrTimeout,
  }) : _client = client ?? http.Client(),
       baseUrl =
           baseUrl ??
           const String.fromEnvironment(
             'OCR_API_BASE_URL',
             defaultValue: 'http://localhost:7860',
           ),
       statusTimeout = statusTimeout ?? const Duration(seconds: 10),
       ocrTimeout =
           ocrTimeout ??
           const Duration(
             seconds: int.fromEnvironment(
               'OCR_TIMEOUT_SECONDS',
               defaultValue: 600,
             ),
           );

  final http.Client _client;
  final String baseUrl;
  final Duration statusTimeout;
  final Duration ocrTimeout;

  Uri _endpoint(String path) {
    final uri = Uri.tryParse(baseUrl.replaceFirst(RegExp(r'/+$'), '') + path);
    if (uri == null ||
        !uri.hasAuthority ||
        !const ['http', 'https'].contains(uri.scheme)) {
      throw const OcrException(
        'Set OCR_API_BASE_URL to the OCR service address.',
      );
    }
    return uri;
  }

  Future<T> _request<T>(
    Future<T> Function() operation,
    Duration timeout,
  ) async {
    try {
      return await operation().timeout(timeout);
    } on TimeoutException {
      throw const OcrException(
        'OCR service timed out. Try again when it is available.',
      );
    } on http.ClientException {
      throw OcrException(
        'Cannot reach OCR service at $baseUrl. Check the service and connection.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw OcrException(
        'OCR service returned an invalid response (HTTP ${response.statusCode}).',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = body is Map ? body['detail'] : null;
      throw OcrException(
        detail is String
            ? detail
            : 'OCR service failed (HTTP ${response.statusCode}).',
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const OcrException('OCR service returned an invalid response.');
    }
    return body;
  }

  Future<void> ensureReady() async {
    final body = _decode(
      await _request(
        () => _client.get(_endpoint('/api/status')),
        statusTimeout,
      ),
    );
    if (body['status'] != 'ready') {
      final detail =
          body['error'] ?? body['status_message'] ?? 'Try again shortly.';
      throw OcrException(
        'OCR model is ${body['status'] ?? 'unavailable'}: $detail',
      );
    }
  }

  Future<String> recognizeImage(
    List<int> bytes, {
    String filename = 'scan.jpg',
  }) async {
    final body = _decode(
      await _request(() async {
        final request = http.MultipartRequest('POST', _endpoint('/api/ocr'))
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: filename),
          );
        return http.Response.fromStream(await _client.send(request));
      }, ocrTimeout),
    );
    if (body['text'] is! String) {
      throw const OcrException('OCR service response is missing text.');
    }
    return (body['text'] as String).trim();
  }

  void close() => _client.close();
}
