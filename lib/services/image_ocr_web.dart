import 'dart:js_util' as js_util;
import 'dart:typed_data';

Future<String> recognizeImage(Uint8List bytes) async {
  final result = await js_util.promiseToFuture<Object?>(
    js_util.callMethod<Object>(
      js_util.globalThis,
      'recognizeImageWithTesseract',
      [js_util.jsify(bytes.toList())],
    ),
  );
  return result?.toString() ?? '';
}
