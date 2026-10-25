import 'dart:convert';
import 'dart:js_util' as js_util;
import 'dart:typed_data';

Future<String> recognizeImage(
  Uint8List bytes, {
  required void Function(String status) onProgress,
}) async {
  js_util.setProperty(
    js_util.globalThis,
    'onOcrProgress',
    js_util.allowInterop((Object? status, Object? progress) {
      onProgress(status?.toString() ?? 'Reading image');
    }),
  );
  try {
    final result = await js_util.promiseToFuture<Object?>(
      js_util.callMethod<Object>(
        js_util.globalThis,
        'recognizeImageWithTesseract',
        [base64Encode(bytes)],
      ),
    );
    return result?.toString() ?? '';
  } finally {
    js_util.setProperty(js_util.globalThis, 'onOcrProgress', null);
  }
}
