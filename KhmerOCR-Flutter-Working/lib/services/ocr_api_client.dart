import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/image_detection.dart';

class OcrException implements Exception {
  const OcrException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OcrRecognitionOptions {
  const OcrRecognitionOptions({
    this.detMode = 'smart_hybrid',
    this.task = 'ocr',
    this.customPrompt = 'OCR:',
    this.maxNewTokens = 1024,
    this.useLora = true,
    this.streamResults = true,
  });

  final String detMode;
  final String task;
  final String customPrompt;
  final int maxNewTokens;
  final bool useLora;
  final bool streamResults;

  OcrRecognitionOptions copyWith({
    String? detMode,
    String? task,
    String? customPrompt,
    int? maxNewTokens,
    bool? useLora,
    bool? streamResults,
  }) => OcrRecognitionOptions(
    detMode: detMode ?? this.detMode,
    task: task ?? this.task,
    customPrompt: customPrompt ?? this.customPrompt,
    maxNewTokens: maxNewTokens ?? this.maxNewTokens,
    useLora: useLora ?? this.useLora,
    streamResults: streamResults ?? this.streamResults,
  );
}

class OcrImageResult {
  const OcrImageResult({required this.text, this.imageSize});

  final String text;
  final ImageSize? imageSize;
}

/// Adapter for the existing Python API. Inference options are owned by the server.
class OcrApiClient {
  OcrApiClient({
    http.Client? client,
    String? baseUrl,
    String? apiKey,
    Duration? statusTimeout,
    Duration? readyTimeout,
    Duration? ocrTimeout,
    Duration? detectionTimeout,
  }) : _client = client ?? http.Client(),
       baseUrl =
           baseUrl ??
           const String.fromEnvironment(
             'OCR_API_BASE_URL',
             defaultValue:
                 'https://dvdlosser--openkhmer-ocr-serve.us-east.modal.run',
           ),
       apiKey = apiKey ?? const String.fromEnvironment('OCR_API_KEY'),
       statusTimeout = statusTimeout ?? const Duration(seconds: 10),
       readyTimeout =
           readyTimeout ??
           const Duration(
             seconds: int.fromEnvironment(
               'OCR_READY_TIMEOUT_SECONDS',
               defaultValue: 900,
             ),
           ),
       ocrTimeout =
           ocrTimeout ??
           const Duration(
             seconds: int.fromEnvironment(
               'OCR_TIMEOUT_SECONDS',
               defaultValue: 600,
             ),
           ),
       detectionTimeout = detectionTimeout ?? const Duration(seconds: 180);

  final http.Client _client;
  final String baseUrl;
  final String apiKey;
  final Duration statusTimeout;
  final Duration readyTimeout;
  final Duration ocrTimeout;
  final Duration detectionTimeout;

  Map<String, String> get _authHeaders => apiKey.isEmpty
      ? const <String, String>{}
      : <String, String>{'x-api-key': apiKey};

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
    final deadline = DateTime.now().add(readyTimeout);
    var lastDetail = 'The model is still starting.';
    while (true) {
      try {
        final response = await _client
            .get(_endpoint('/api/status'), headers: _authHeaders)
            .timeout(statusTimeout);
        if (response.statusCode == 401 || response.statusCode == 403) {
          _decode(response);
        }
        if (response.statusCode >= 500) {
          lastDetail = 'OCR service is starting (HTTP ${response.statusCode}).';
        } else {
          final body = _decode(response);
          if (body['status'] == 'ready') return;
          final status = body['status']?.toString() ?? 'unavailable';
          final detail =
              body['error'] ?? body['status_message'] ?? 'Try again shortly.';
          if (status != 'loading') {
            throw OcrException('OCR model is $status: $detail');
          }
          lastDetail = 'OCR model is starting: $detail';
        }
      } on TimeoutException {
        lastDetail = 'Waiting for the OCR service to start.';
      } on http.ClientException {
        lastDetail = 'Cannot reach OCR service at $baseUrl while it starts.';
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw OcrException('$lastDetail Please try again shortly.');
      }
      await Future<void>.delayed(
        remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2),
      );
    }
  }

  Future<String> recognizeImage(
    List<int> bytes, {
    String filename = 'scan.jpg',
  }) async => (await recognizeImageWithOptions(bytes, filename: filename)).text;

  Future<OcrImageResult> recognizeImageWithOptions(
    List<int> bytes, {
    String filename = 'scan.jpg',
    OcrRecognitionOptions options = const OcrRecognitionOptions(),
    List<String>? selectedRegionIds,
    void Function(int current, int total)? onRegionProgress,
  }) => _request(
    () => options.streamResults
        ? _recognizeStream(
            bytes,
            filename,
            options,
            selectedRegionIds,
            onRegionProgress,
          )
        : _recognizeJson(bytes, filename, options, selectedRegionIds),
    ocrTimeout,
  );

  Future<OcrImageResult> _recognizeJson(
    List<int> bytes,
    String filename,
    OcrRecognitionOptions options,
    List<String>? selectedRegionIds,
  ) async {
    final request = _buildOcrRequest(
      '/api/ocr',
      bytes,
      filename,
      options,
      selectedRegionIds,
    );
    final body = _decode(
      await http.Response.fromStream(await _client.send(request)),
    );
    return _resultFromBody(body);
  }

  Future<OcrImageResult> _recognizeStream(
    List<int> bytes,
    String filename,
    OcrRecognitionOptions options,
    List<String>? selectedRegionIds,
    void Function(int current, int total)? onRegionProgress,
  ) async {
    final request = _buildOcrRequest(
      '/api/ocr/stream',
      bytes,
      filename,
      options,
      selectedRegionIds,
    );
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final buffered = await http.Response.fromStream(response);
      _decode(buffered);
      throw OcrException('OCR service failed (HTTP ${response.statusCode}).');
    }

    Map<String, dynamic>? result;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final encoded = line.substring(5).trim();
      if (encoded.isEmpty) continue;
      final dynamic event;
      try {
        event = jsonDecode(encoded);
      } on FormatException {
        continue;
      }
      if (event is! Map<String, dynamic>) continue;
      switch (event['type']) {
        case 'region_start':
          final current = event['index'];
          final total = event['total'];
          if (current is num && total is num) {
            onRegionProgress?.call(current.toInt(), total.toInt());
          }
          break;
        case 'done':
          result = event;
          break;
        case 'error':
          throw OcrException(
            event['error'] is String
                ? event['error'] as String
                : 'OCR service failed during recognition.',
          );
        default:
          break;
      }
    }
    if (result == null) {
      throw const OcrException('OCR stream ended before returning a result.');
    }
    return _resultFromBody(result);
  }

  http.MultipartRequest _buildOcrRequest(
    String path,
    List<int> bytes,
    String filename,
    OcrRecognitionOptions options,
    List<String>? selectedRegionIds,
  ) {
    final request = http.MultipartRequest('POST', _endpoint(path))
      ..fields['task'] = options.task
      ..fields['max_new_tokens'] = '${options.maxNewTokens}'
      ..fields['use_lora'] = options.useLora ? 'true' : 'false'
      ..fields['det_mode'] = options.detMode
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    request.headers.addAll(_authHeaders);
    if (options.task == 'custom') {
      request.fields['custom_prompt'] = options.customPrompt;
    }
    if (selectedRegionIds != null) {
      request.fields['region_ids'] = jsonEncode(selectedRegionIds);
    }
    return request;
  }

  OcrImageResult _resultFromBody(Map<String, dynamic> body) {
    if (body['text'] is! String) {
      throw const OcrException('OCR service response is missing text.');
    }
    ImageSize? imageSize;
    if (body['image_size'] is Map) {
      try {
        imageSize = ImageSize.fromJson(body['image_size']);
      } on FormatException {
        imageSize = null;
      }
    }
    return OcrImageResult(
      text: (body['text'] as String).trim(),
      imageSize: imageSize,
    );
  }

  Future<ImageDetectionResult> detectImage(
    List<int> bytes, {
    String filename = 'scan.jpg',
    OcrRecognitionOptions options = const OcrRecognitionOptions(),
  }) async {
    await ensureReady();
    final body = _decode(
      await _request(() async {
        final request = http.MultipartRequest('POST', _endpoint('/api/detect'))
          ..fields['det_mode'] = options.detMode
          ..fields['task'] = options.task
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: filename),
          );
        request.headers.addAll(_authHeaders);
        return http.Response.fromStream(await _client.send(request));
      }, detectionTimeout),
    );
    try {
      return ImageDetectionResult.fromJson(body);
    } on FormatException {
      throw const OcrException(
        'OCR service returned invalid text-region detection data.',
      );
    }
  }

  void close() => _client.close();
}
