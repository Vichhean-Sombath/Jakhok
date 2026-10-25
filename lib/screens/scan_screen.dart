import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../services/file_text_extractor.dart';
import '../services/image_ocr_stub.dart'
    if (dart.library.html) '../services/image_ocr_web.dart'
    as web_image_ocr;
import '../widgets/scan_overlay.dart';
import 'chat_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    required this.state,
    this.returnToCaller = false,
    this.openCameraInitially = false,
    this.openGalleryInitially = false,
    this.openFilePickerInitially = false,
  });
  final AppState state;
  final bool returnToCaller;
  final bool openCameraInitially;
  final bool openGalleryInitially;
  final bool openFilePickerInitially;
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _camera;
  File? _image;
  Uint8List? _imageBytes;
  String? _documentName;
  List<int>? _documentBytes;
  bool _cameraUnavailable = false;
  bool _busy = false;
  String? _ocrStatus;
  bool _flash = false;
  String? _error;

  bool get _hasImage => _image != null || _imageBytes != null;

  @override
  void initState() {
    super.initState();
    if (widget.openFilePickerInitially) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickFile());
    } else if (widget.openGalleryInitially) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _gallery());
    } else if (widget.openCameraInitially && !kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeSystemPhoto());
    } else {
      _initializeCamera();
    }
  }

  Future<void> _takeSystemPhoto() async {
    final hadImage = _hasImage;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      if (!mounted) return;
      if (picked == null) {
        if (!hadImage) Navigator.of(context).pop();
        return;
      }
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = File(picked.path);
        _imageBytes = bytes;
        _documentName = null;
        _documentBytes = null;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cameraUnavailable = true;
          _error = 'Camera not available. Choose a photo or upload a file.';
        });
      }
    }
  }

  void _retake() {
    if (widget.openCameraInitially && !kIsWeb) {
      _takeSystemPhoto();
      return;
    }
    setState(() {
      _image = null;
      _imageBytes = null;
      _documentName = null;
      _documentBytes = null;
    });
  }

  Future<void> _initializeCamera() async {
    try {
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        if (mounted) {
          setState(() => _cameraUnavailable = true);
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Camera access is required'),
              content: const Text(
                'Allow camera access to scan documents. You can also choose an image from your gallery.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await openAppSettings();
                  },
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );
        }
        return;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty)
        throw CameraException('no-camera', 'No camera available');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraUnavailable = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cameraUnavailable = true);
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    try {
      final shot = await _camera?.takePicture();
      if (shot != null && mounted) {
        final bytes = await shot.readAsBytes();
        setState(() {
          _image = File(shot.path);
          _imageBytes = bytes;
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Camera not available. Choose an image from your gallery.',
        );
    }
  }

  Future<void> _gallery() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        setState(() {
          _image = kIsWeb ? null : File(picked.path);
          _imageBytes = bytes;
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the photo library.');
    }
  }

  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      if (picked == null || !mounted) return;
      final extension = (picked.extension ?? '').toLowerCase();
      if (const {
        'mp3',
        'm4a',
        'wav',
        'aac',
        'ogg',
        'flac',
        'mp4',
        'mov',
        'avi',
        'mkv',
        'webm',
        'mpeg',
        'mpg',
      }.contains(extension)) {
        setState(
          () => _error =
              'Audio and video need transcription. Import a subtitle file such as SRT or VTT instead.',
        );
        return;
      }
      final size = await picked.length();
      if (size != null && size > 100 * 1024 * 1024) {
        setState(() => _error = 'Files larger than 100 MB are not supported.');
        return;
      }
      final bytes = await picked.readAsBytes();
      if (_isImageFile(extension, bytes)) {
        var path = kIsWeb ? null : picked.path;
        if (path == null && !kIsWeb) {
          final tempDirectory = await getTemporaryDirectory();
          final imageFile = File(
            '${tempDirectory.path}/picked_${DateTime.now().microsecondsSinceEpoch}.$extension',
          );
          await imageFile.writeAsBytes(bytes, flush: true);
          path = imageFile.path;
        }
        setState(() {
          _image = path == null ? null : File(path);
          _imageBytes = Uint8List.fromList(bytes);
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
      } else {
        setState(() {
          _image = null;
          _imageBytes = null;
          _documentName = picked.name;
          _documentBytes = bytes;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the selected file.');
    }
  }

  bool _isImageFile(String extension, List<int>? bytes) {
    if (const {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'tif',
      'tiff',
      'avif',
    }.contains(extension)) {
      return true;
    }
    if (bytes == null || bytes.length < 4) return false;
    final b = bytes;
    return (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (b.length >= 8 &&
            b[0] == 0x89 &&
            b[1] == 0x50 &&
            b[2] == 0x4e &&
            b[3] == 0x47) ||
        (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) ||
        (b[0] == 0x42 && b[1] == 0x4d) ||
        (b.length >= 12 &&
            b[0] == 0x52 &&
            b[1] == 0x49 &&
            b[2] == 0x46 &&
            b[3] == 0x46 &&
            b[8] == 0x57 &&
            b[9] == 0x45 &&
            b[10] == 0x42 &&
            b[11] == 0x50) ||
        (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2a && b[3] == 0x00) ||
        (b[0] == 0x4d && b[1] == 0x4d && b[2] == 0x00 && b[3] == 0x2a);
  }

  bool _isPdfFile(String filename, List<int> bytes) =>
      filename.toLowerCase().endsWith('.pdf') ||
      (bytes.length >= 4 &&
          bytes[0] == 0x25 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x44 &&
          bytes[3] == 0x46);

  Future<void> _extract() async {
    if ((!_hasImage && _documentBytes == null) || _busy) return;
    setState(() {
      _busy = true;
      _ocrStatus = 'Preparing OCR…';
      _error = null;
    });
    TextRecognizer? recognizer;
    try {
      String text;
      if (_hasImage) {
        if (kIsWeb) {
          text = (await web_image_ocr.recognizeImage(
            _imageBytes!,
            onProgress: (status) {
              if (mounted) setState(() => _ocrStatus = _friendlyOcrStatus(status));
            },
          )).trim();
        } else {
          final image = _image;
          if (image == null) {
            throw UnsupportedError(
              'Image OCR is unavailable on this platform.',
            );
          }
          recognizer = TextRecognizer(script: TextRecognitionScript.latin);
          final result = await recognizer.processImage(
            InputImage.fromFilePath(image.path),
          );
          text = result.text.trim();
        }
      } else {
        if (_isPdfFile(_documentName!, _documentBytes!)) {
          final pageTexts = await FileTextExtractor.extractPdfPages(
            _documentBytes!,
          );
          if (pageTexts.any((pageText) => pageText.isEmpty)) {
            recognizer = TextRecognizer(script: TextRecognitionScript.latin);
            text = await _extractScannedPdf(
              _documentBytes!,
              pageTexts,
              recognizer,
            );
          } else {
            text = pageTexts.join('\n\n');
          }
        } else {
          text = (await FileTextExtractor.extract(
            _documentName!,
            _documentBytes!,
          )).trim();
        }
      }
      if (text.isEmpty) {
        setState(() {
          _error = _hasImage
              ? 'No text found in image. Try another image or retake the photo.'
              : 'No readable text found in this file. Check that its pages are clear and readable.';
          _busy = false;
          _ocrStatus = null;
        });
        return;
      }
      final now = DateTime.now();
      var savedImagePath = '';
      if (_image != null) {
        final appDirectory = await getApplicationDocumentsDirectory();
        final imageDirectory = Directory('${appDirectory.path}/scans');
        await imageDirectory.create(recursive: true);
        final savedImage = await _image!.copy(
          '${imageDirectory.path}/${now.microsecondsSinceEpoch}.jpg',
        );
        savedImagePath = savedImage.path;
      }
      final doc = ScannedDocument(
        id: '${now.microsecondsSinceEpoch}',
        name:
            _documentName ??
            'Scan_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}',
        createdAt: now,
        imagePath: savedImagePath,
        text: text,
        imageBytes: _imageBytes,
      );
      await widget.state.addDocument(doc);
      if (!mounted) return;
      if (widget.returnToCaller) {
        Navigator.of(context).pop(doc);
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            document: doc,
            state: widget.state,
            showExtractedText: true,
          ),
        ),
      );
    } on UnsupportedError catch (error) {
      if (mounted) {
        setState(() {
          _error =
              error.message?.toString() ??
              'This file type is not supported for text extraction.';
          _busy = false;
          _ocrStatus = null;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _error = kIsWeb && _hasImage
              ? 'Could not recognize text in this image. Check your connection and try again.'
              : 'Couldn’t read this file. Import an image, PDF, Office document, text file, EPUB, subtitle, or ZIP archive.';
          _busy = false;
          _ocrStatus = null;
        });
    } finally {
      await recognizer?.close();
    }
  }

  String _friendlyOcrStatus(String status) {
    final value = status.toLowerCase();
    if (value.contains('traineddata') || value.contains('language')) {
      return 'Loading language data…';
    }
    if (value.contains('recogniz')) return 'Reading text…';
    if (value.contains('core') || value.contains('initializ')) {
      return 'Preparing OCR…';
    }
    return 'Processing image…';
  }

  Future<String> _extractScannedPdf(
    List<int> bytes,
    List<String> pageTexts,
    TextRecognizer recognizer,
  ) async {
    final pdf = await PdfDocument.openData(Uint8List.fromList(bytes));
    final tempDirectory = await getTemporaryDirectory();
    try {
      for (var pageNumber = 1; pageNumber <= pdf.pagesCount; pageNumber++) {
        if (pageNumber <= pageTexts.length &&
            pageTexts[pageNumber - 1].isNotEmpty) {
          continue;
        }
        final page = await pdf.getPage(pageNumber);
        try {
          final image = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.png,
          );
          if (image == null) continue;
          final imageFile = File(
            '${tempDirectory.path}/pdf_ocr_${DateTime.now().microsecondsSinceEpoch}_$pageNumber.png',
          );
          try {
            await imageFile.writeAsBytes(image.bytes, flush: true);
            final pageText = await recognizer.processImage(
              InputImage.fromFilePath(imageFile.path),
            );
            if (pageText.text.trim().isNotEmpty) {
              pageTexts[pageNumber - 1] = pageText.text.trim();
            }
          } finally {
            if (await imageFile.exists()) await imageFile.delete();
          }
        } finally {
          await page.close();
        }
      }
    } finally {
      await pdf.close();
    }
    return pageTexts.join('\n\n');
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hasImage)
            _imageBytes != null
                ? Image.memory(_imageBytes!, fit: BoxFit.contain)
                : Image.file(_image!, fit: BoxFit.contain)
          else if (_documentName != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.description_outlined,
                      color: Colors.white,
                      size: 68,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _documentName!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 17),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ready to extract text',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            )
          else if (_camera?.value.isInitialized == true)
            CameraPreview(_camera!)
          else
            Container(
              color: const Color(0xFF171717),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.document_scanner_outlined,
                      color: Colors.white70,
                      size: 54,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _cameraUnavailable
                          ? 'Camera not available'
                          : 'Starting camera…',
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (_cameraUnavailable)
                      TextButton.icon(
                        onPressed: _gallery,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Choose from gallery'),
                      ),
                  ],
                ),
              ),
            ),
          if (!_hasImage && !_cameraUnavailable) ...[
            const ScanOverlay(),
            const Positioned(
              top: 25,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Position document in frame',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    shadows: [Shadow(blurRadius: 5, color: Colors.black)],
                  ),
                ),
              ),
            ),
          ],
          Positioned(
            top: 4,
            left: 4,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          if (_hasImage || _documentBytes != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: 22,
              child: Row(
                children: [
                  TextButton(
                    onPressed: _retake,
                    child: const Text(
                      'Retake',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy ? null : _extract,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(160, 48),
                    ),
                    child: _busy
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _ocrStatus ?? 'Working…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          )
                        : const Text('Extract Text'),
                  ),
                ],
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    onPressed: () async {
                      try {
                        final c = _camera;
                        if (c != null && c.value.isInitialized) {
                          _flash = !_flash;
                          await c.setFlashMode(
                            _flash ? FlashMode.torch : FlashMode.off,
                          );
                          setState(() {});
                        }
                      } catch (_) {}
                    },
                    icon: Icon(
                      _flash
                          ? Icons.flash_on_outlined
                          : Icons.flash_off_outlined,
                      color: Colors.white,
                    ),
                    iconSize: 26,
                  ),
                  GestureDetector(
                    onTap: _camera?.value.isInitialized == true
                        ? _capture
                        : _gallery,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _gallery,
                    icon: const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.white,
                    ),
                    iconSize: 26,
                  ),
                  IconButton(
                    onPressed: _pickFile,
                    tooltip: 'Choose a document',
                    icon: const Icon(Icons.attach_file, color: Colors.white),
                    iconSize: 26,
                  ),
                ],
              ),
            ),
          if (_error != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: !_hasImage && _documentBytes == null ? 115 : 88,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.72),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
