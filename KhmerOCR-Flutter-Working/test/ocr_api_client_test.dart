import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khmer_ocr_flutter/services/ocr_api_client.dart';
import 'package:khmer_ocr_flutter/services/pdf_ocr.dart';

void main() {
  test(
    'uploads multipart file, retains server defaults and Khmer text',
    () async {
      final client = OcrApiClient(
        apiKey: 'test-modal-key',
        client: MockClient((request) async {
          expect(request.headers['x-api-key'], 'test-modal-key');
          if (request.url.path == '/api/status')
            return http.Response('{"status":"ready"}', 200);
          expect(request.method, 'POST');
          expect(request.url.path, '/api/ocr');
          expect(
            request.headers['content-type'],
            startsWith('multipart/form-data'),
          );
          expect(request.body, contains('name="file"; filename="page.png"'));
          expect(request.body, contains('name="use_lora"'));
          expect(request.body, contains('name="det_mode"'));
          expect(request.body, contains('name="max_new_tokens"'));
          return http.Response.bytes(utf8.encode('{"text":"សួស្តី"}'), 200);
        }),
      );
      await client.ensureReady();
      expect(
        (await client.recognizeImageWithOptions(
          [1, 2, 3],
          filename: 'page.png',
          options: const OcrRecognitionOptions(streamResults: false),
        )).text,
        'សួស្តី',
      );
      client.close();
    },
  );
  for (final status in ['loading', 'error']) {
    test('reports model $status', () async {
      final client = OcrApiClient(
        readyTimeout: Duration.zero,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'status': status, 'status_message': 'Please wait'}),
            200,
          ),
        ),
      );
      await expectLater(client.ensureReady(), throwsA(isA<OcrException>()));
      client.close();
    });
  }
  for (final code in [400, 422, 500, 503]) {
    test('reports HTTP $code detail', () async {
      final client = OcrApiClient(
        client: MockClient(
          (_) async => http.Response('{"detail":"Service message"}', code),
        ),
      );
      await expectLater(
        client.recognizeImage([1]),
        throwsA(
          isA<OcrException>().having(
            (e) => e.message,
            'message',
            'Service message',
          ),
        ),
      );
      client.close();
    });
  }
  for (final body in ['not json', '[]', '{}', '{"text":42}']) {
    test('rejects malformed response $body', () async {
      final client = OcrApiClient(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        client.recognizeImage([1]),
        throwsA(isA<OcrException>()),
      );
      client.close();
    });
  }
  test('empty OCR result is retained for existing no-text handling', () async {
    final client = OcrApiClient(
      client: MockClient((_) async => http.Response('{"text":""}', 200)),
    );
    expect(
      (await client.recognizeImageWithOptions([
        1,
      ], options: const OcrRecognitionOptions(streamResults: false))).text,
      '',
    );
    client.close();
  });
  test('connection failures are actionable', () async {
    final client = OcrApiClient(
      readyTimeout: Duration.zero,
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      client.ensureReady(),
      throwsA(
        isA<OcrException>().having(
          (e) => e.message,
          'message',
          contains('Cannot reach'),
        ),
      ),
    );
    client.close();
  });
  test('status and OCR timeouts do not retry', () async {
    var count = 0;
    final client = OcrApiClient(
      statusTimeout: const Duration(milliseconds: 1),
      readyTimeout: const Duration(milliseconds: 1),
      ocrTimeout: const Duration(milliseconds: 1),
      client: MockClient((_) {
        count++;
        return Completer<http.Response>().future;
      }),
    );
    await expectLater(client.ensureReady(), throwsA(isA<OcrException>()));
    await expectLater(client.recognizeImage([1]), throwsA(isA<OcrException>()));
    expect(count, 2);
    client.close();
  });
  test('mixed PDF preserves text and renders missing pages in order', () async {
    final rendered = <int>[];
    final result = await fillMissingPdfText(
      pageTexts: ['first', '', 'third', ''],
      renderPage: (n) async {
        rendered.add(n);
        return [n];
      },
      recognize: (bytes) async => 'page ${bytes.single}',
      isActive: () => true,
    );
    expect(rendered, [2, 4]);
    expect(result, 'first\n\npage 2\n\nthird\n\npage 4');
  });
  test('PDF failure aborts without returning partial text', () async {
    await expectLater(
      fillMissingPdfText(
        pageTexts: ['first', ''],
        renderPage: (_) async => throw const OcrException('render failed'),
        recognize: (_) async => 'unused',
        isActive: () => true,
      ),
      throwsA(isA<OcrException>()),
    );
  });
  test('cancelled PDF does not upload rendered page', () async {
    var active = true;
    await expectLater(
      fillMissingPdfText(
        pageTexts: [''],
        renderPage: (_) async {
          active = false;
          return [1];
        },
        recognize: (_) async {
          fail('Must not upload stale image');
        },
        isActive: () => active,
      ),
      throwsA(isA<OcrException>()),
    );
  });
}
