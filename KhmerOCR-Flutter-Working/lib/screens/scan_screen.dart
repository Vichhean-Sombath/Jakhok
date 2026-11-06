import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../models/image_detection.dart';
import '../services/file_text_extractor.dart';
import '../services/ocr_api_client.dart';
import '../services/pdf_ocr.dart';
import '../widgets/detection_image_view.dart';
import '../widgets/ocr_settings_sheet.dart';
import '../widgets/scan_overlay.dart';
import 'chat_screen.dart';
import 'detail_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    required this.state,
    this.returnToCaller = false,
    this.openCameraInitially = false,
    this.openGalleryInitially = false,
    this.openFilePickerInitially = false,
    this.autoExtractOnSelect = false,
  });
  final AppState state;
  final bool returnToCaller;
  final bool openCameraInitially;
  final bool openGalleryInitially;
  final bool openFilePickerInitially;
  final bool autoExtractOnSelect;
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _camera;
  File? _image;
  Uint8List? _imageBytes;
  String? _documentName;
  String _imageFilename = 'scan.jpg';
  List<int>? _documentBytes;
  bool _cameraUnavailable = false;
  bool _busy = false;
  final _ocr = OcrApiClient();
  int _scanVersion = 0;
  String? _ocrStatus;
  bool _flash = false;
  String? _error;
  int _detectionVersion = 0;
  bool _detecting = false;
  ImageDetectionResult? _detectionResult;
  String? _detectionError;
  OcrRecognitionOptions _options = const OcrRecognitionOptions();
  final Set<String> _selectedBoxIds = {};
  bool _backgroundJobStarted = false;
  bool _handledBackgroundCompletion = false;

  bool get _hasImage => _image != null || _imageBytes != null;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onAppStateChanged);
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
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        if (mounted) {
          setState(() {
            _cameraUnavailable = true;
            _error =
                'Camera permission was denied. Upload a photo or file instead.';
          });
        }
        return;
      }
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      if (!mounted) return;
      if (picked == null) {
        if (!hadImage && widget.openCameraInitially) {
          Navigator.of(context).pop();
        }
        return;
      }
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _scanVersion++;
        _resetDetection();
        _busy = false;
        _ocrStatus = null;
        _image = File(picked.path);
        _imageBytes = bytes;
        _imageFilename = picked.name;
        _documentName = null;
        _documentBytes = null;
        _error = null;
      });
      unawaited(_beginDetection(bytes, filename: picked.name));
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
      setState(() {
        _scanVersion++;
        _busy = false;
        _ocrStatus = null;
      });
      _takeSystemPhoto();
      return;
    }
    setState(() {
      _scanVersion++;
      _resetDetection();
      _busy = false;
      _ocrStatus = null;
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
    widget.state.removeListener(_onAppStateChanged);
    _scanVersion++;
    _detectionVersion++;
    _ocr.close();
    _camera?.dispose();
    super.dispose();
  }

  void _resetDetection() {
    _detectionVersion++;
    _detecting = false;
    _detectionResult = null;
    _detectionError = null;
    _selectedBoxIds.clear();
  }

  Future<void> _beginDetection(
    List<int> bytes, {
    required String filename,
  }) async {
    final version = ++_detectionVersion;
    setState(() {
      _detecting = true;
      _detectionResult = null;
      _detectionError = null;
    });
    await _runDetection(version, bytes, filename);
  }

  Future<void> _runDetection(
    int version,
    List<int> bytes,
    String filename,
  ) async {
    try {
      final result = await _ocr.detectImage(
        bytes,
        filename: filename,
        options: _options,
      );
      if (!mounted || version != _detectionVersion) return;
      setState(() {
        _detectionResult = result;
        _selectedBoxIds
          ..clear()
          ..addAll(result.boxes.map((box) => box.id));
        _detecting = false;
      });
    } on OcrException catch (error) {
      if (!mounted || version != _detectionVersion) return;
      setState(() {
        _detectionError = error.message;
        _detecting = false;
      });
    } catch (_) {
      if (!mounted || version != _detectionVersion) return;
      setState(() {
        _detectionError =
            'Could not detect text regions. Check the service connection.';
        _detecting = false;
      });
    }
  }

  Future<void> _capture() async {
    try {
      final shot = await _camera?.takePicture();
      if (shot != null && mounted) {
        final bytes = await shot.readAsBytes();
        if (!mounted) return;
        setState(() {
          _scanVersion++;
          _resetDetection();
          _busy = false;
          _ocrStatus = null;
          _image = kIsWeb ? null : File(shot.path);
          _imageBytes = bytes;
          _imageFilename = shot.name;
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
        unawaited(_beginDetection(bytes, filename: shot.name));
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
        if (!mounted) return;
        setState(() {
          _scanVersion++;
          _resetDetection();
          _busy = false;
          _ocrStatus = null;
          _image = kIsWeb ? null : File(picked.path);
          _imageBytes = bytes;
          _imageFilename = picked.name;
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
        unawaited(_beginDetection(bytes, filename: picked.name));
      } else if (picked == null && mounted && widget.openGalleryInitially) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the photo library.');
    }
  }

  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      if (picked == null || !mounted) {
        if (picked == null && mounted && widget.openFilePickerInitially) {
          Navigator.of(context).pop();
        }
        return;
      }
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
      if (!mounted) return;
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
        if (!mounted) return;
        setState(() {
          _scanVersion++;
          _resetDetection();
          _busy = false;
          _ocrStatus = null;
          _image = path == null ? null : File(path);
          _imageBytes = Uint8List.fromList(bytes);
          _imageFilename = picked.name;
          _documentName = null;
          _documentBytes = null;
          _error = null;
        });
        unawaited(_beginDetection(_imageBytes!, filename: picked.name));
      } else {
        setState(() {
          _scanVersion++;
          _resetDetection();
          _busy = false;
          _ocrStatus = null;
          _image = null;
          _imageBytes = null;
          _documentName = picked.name;
          _documentBytes = bytes;
          _error = null;
        });
        if (widget.autoExtractOnSelect) await _extract();
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

  void _toggleRegion(String id) {
    setState(() {
      if (!_selectedBoxIds.add(id)) _selectedBoxIds.remove(id);
    });
  }

  void _selectAllRegions(bool selected) {
    final boxes = _detectionResult?.boxes ?? const <DetectedTextBox>[];
    setState(() {
      _selectedBoxIds
        ..clear()
        ..addAll(selected ? boxes.map((box) => box.id) : const <String>[]);
    });
  }

  Future<void> _openRecognitionSettings() async {
    final previous = _options;
    final updated = await showOcrSettingsSheet(context, initial: previous);
    if (!mounted || updated == null) return;
    final needsRedetection =
        previous.detMode != updated.detMode || previous.task != updated.task;
    setState(() => _options = updated);
    final bytes = _imageBytes;
    if (needsRedetection && bytes != null) {
      unawaited(_beginDetection(bytes, filename: _imageFilename));
    }
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final job = widget.state.backgroundOcrJob;
    if (!_backgroundJobStarted || job == null) return;
    if (job.status == BackgroundOcrStatus.complete && job.document != null) {
      setState(() {
        _busy = false;
        _ocrStatus = 'Scan complete';
      });
      _openCompletedJobIfVisible();
    } else if (job.status == BackgroundOcrStatus.failed) {
      setState(() {
        _busy = false;
        _ocrStatus = null;
        _error = job.error;
      });
    } else {
      setState(() {
        _busy = true;
        _ocrStatus = job.progressText;
      });
    }
  }

  void _openCompletedJobIfVisible() {
    final job = widget.state.backgroundOcrJob;
    if (!mounted ||
        !_backgroundJobStarted ||
        _handledBackgroundCompletion ||
        job == null ||
        job.status != BackgroundOcrStatus.complete ||
        job.document == null ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    final document = job.document!;
    _handledBackgroundCompletion = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      widget.state.dismissBackgroundOcrJob();
      if (widget.returnToCaller) {
        Navigator.of(context).pop(document);
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DetailScreen(
              document: document,
              state: widget.state,
              isScanResult: true,
            ),
          ),
        );
      }
    });
  }

  Future<void> _extract() async {
    if ((!_hasImage && _documentBytes == null) || _busy) return;
    setState(() {
      _busy = true;
      _ocrStatus = 'Preparing OCR…';
      _error = null;
    });
    final version = ++_scanVersion;
    bool active() =>
        mounted &&
        version == _scanVersion &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    final sourceBytes = _imageBytes;
    final sourceName = _documentName;
    final documentBytes = _documentBytes;
    try {
      String text;
      if (_hasImage) {
        final detection = _detectionResult;
        final boxes = detection?.boxes ?? const <DetectedTextBox>[];
        final selected = _selectedBoxIds.toList(growable: false);
        if (detection != null && boxes.isNotEmpty && selected.isEmpty) {
          setState(() {
            _error =
                'Select at least one text region, or choose Full image in settings.';
            _busy = false;
          });
          return;
        }
        if (detection != null && boxes.isEmpty) {
          setState(() {
            _error =
                'No regions were found. Choose another detection engine or try a clearer image.';
            _busy = false;
          });
          return;
        }
        widget.state.startBackgroundOcr(
          name: _imageFilename,
          imageBytes: Uint8List.fromList(sourceBytes!),
          detection: detection,
          selectedRegionIds: detection == null ? null : selected,
          options: _options,
        );
        _backgroundJobStarted = true;
        setState(() => _ocrStatus = 'Preparing OCR…');
        return;
      } else {
        if (_isPdfFile(sourceName!, documentBytes!)) {
          final pageTexts = await FileTextExtractor.extractPdfPages(
            documentBytes,
          );
          if (pageTexts.any((pageText) => pageText.isEmpty)) {
            await _ocr.ensureReady();
            if (!active()) return;
            text = await _extractScannedPdf(documentBytes, pageTexts, active);
          } else {
            text = pageTexts.join('\n\n');
          }
        } else {
          text = (await FileTextExtractor.extract(
            sourceName,
            documentBytes,
          )).trim();
        }
      }
      if (!active()) return;
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
      if (!active()) return;
      final now = DateTime.now();
      final doc = ScannedDocument(
        id: '${now.microsecondsSinceEpoch}',
        name: sourceName,
        createdAt: now,
        imagePath: '',
        text: text,
      );
      await widget.state.addDocument(doc);
      if (!mounted) return;
      if (widget.returnToCaller) {
        Navigator.of(context).pop(doc);
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => widget.autoExtractOnSelect
              ? DetailScreen(
                  document: doc,
                  state: widget.state,
                  isScanResult: true,
                )
              : ChatScreen(
                  document: doc,
                  state: widget.state,
                  showExtractedText: true,
                ),
        ),
      );
    } on OcrException catch (error) {
      if (active()) {
        setState(() {
          _error = error.message;
          _busy = false;
          _ocrStatus = null;
        });
      }
    } on UnsupportedError catch (error) {
      if (active()) {
        setState(() {
          _error =
              error.message?.toString() ??
              'This file type is not supported for text extraction.';
          _busy = false;
          _ocrStatus = null;
        });
      }
    } catch (_) {
      if (active())
        setState(() {
          _error = kIsWeb && _hasImage
              ? 'Could not recognize text in this image. Check your connection and try again.'
              : 'Couldn’t read this file. Import an image, PDF, Office document, text file, EPUB, subtitle, or ZIP archive.';
          _busy = false;
          _ocrStatus = null;
        });
    }
  }

  Future<String> _extractScannedPdf(
    List<int> bytes,
    List<String> pageTexts,
    bool Function() active,
  ) async {
    final pdf = await PdfDocument.openData(Uint8List.fromList(bytes));
    try {
      return await fillMissingPdfText(
        pageTexts: pageTexts,
        isActive: active,
        onProgress: (page, total) {
          if (active()) {
            setState(() => _ocrStatus = 'Reading page $page/$total…');
          }
        },
        recognize: (bytes) => _ocr.recognizeImage(bytes, filename: 'page.png'),
        renderPage: (number) async {
          final page = await pdf.getPage(number);
          try {
            final image = await page.render(
              width: page.width * 2,
              height: page.height * 2,
              format: PdfPageImageFormat.png,
            );
            if (image == null) {
              throw OcrException('Could not render PDF page $number.');
            }
            return image.bytes;
          } finally {
            await page.close();
          }
        },
      );
    } finally {
      await pdf.close();
    }
  }

  Widget _detectionStatus() {
    final IconData icon;
    final String message;
    final Color iconColor;
    if (_detecting) {
      icon = Icons.search;
      iconColor = Colors.white70;
      message = 'Finding text regions…';
    } else if (_detectionError != null) {
      icon = Icons.warning_amber_rounded;
      iconColor = const Color(0xFFFFD166);
      message = 'Box detection failed: $_detectionError';
    } else if (_detectionResult != null && _detectionResult!.boxes.isEmpty) {
      icon = Icons.info_outline;
      iconColor = Colors.white70;
      message = 'No text regions detected';
    } else if (_detectionResult != null) {
      final count = _detectionResult!.boxes.length;
      icon = Icons.check_circle_outline;
      iconColor = const Color(0xFF5EE6A8);
      message = '$count text region${count == 1 ? '' : 's'} found';
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.76),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          if (_detecting) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _regionSelectionControls() {
    final boxes = _detectionResult?.boxes ?? const <DetectedTextBox>[];
    final selectedCount = _selectedBoxIds.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.78),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$selectedCount of ${boxes.length} regions selected · tap boxes to toggle',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: 'Select all regions',
            onPressed: _busy ? null : () => _selectAllRegions(true),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.select_all, color: Colors.white, size: 21),
          ),
          IconButton(
            tooltip: 'Clear selection',
            onPressed: _busy ? null : () => _selectAllRegions(false),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.deselect, color: Colors.white, size: 20),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hasImage)
            Positioned.fill(
              child: DetectionImageView(
                imageProvider: _imageBytes != null
                    ? MemoryImage(_imageBytes!)
                    : FileImage(_image!),
                imageSize: _detectionResult?.imageSize,
                boxes: _detectionResult?.boxes ?? const [],
                selectedBoxIds: Set<String>.unmodifiable(_selectedBoxIds),
                onBoxTap: _busy ? null : _toggleRegion,
              ),
            )
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
          if (_busy) ...[
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.black.withOpacity(.48)),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    label:
                        '${_ocrStatus ?? 'Scan in progress'}. Detailed scans can take a while. Your results will appear here when the scan finishes.',
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xF0181818),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white24),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 24,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _ocrStatus ?? 'Scan in progress',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      'This scan will keep running while you use the rest of the app.',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (_backgroundJobStarted) ...[
                            const SizedBox(height: 12),
                            TextButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Continue in background'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
              tooltip: _backgroundJobStarted
                  ? 'Leave scan running'
                  : 'Close scanner',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          if (_hasImage || _documentBytes != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _retake,
                      child: const Text(
                        'Retake',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    const Spacer(),
                    if (_hasImage)
                      IconButton(
                        onPressed: _busy ? null : _openRecognitionSettings,
                        tooltip: 'Recognition settings',
                        icon: const Icon(
                          Icons.tune_rounded,
                          color: Colors.white,
                        ),
                      ),
                    FilledButton(
                      onPressed:
                          _busy ||
                              _detecting ||
                              (_detectionResult != null &&
                                  _detectionResult!.boxes.isEmpty)
                          ? null
                          : _extract,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(0, 48),
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
                          : Text(
                              _error != null
                                  ? 'Retry'
                                  : _hasImage
                                  ? 'Scan ${_selectedBoxIds.length}'
                                  : 'Extract Text',
                            ),
                    ),
                  ],
                ),
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
          if (_hasImage)
            Positioned(top: 54, left: 16, right: 16, child: _detectionStatus()),
          if (_hasImage &&
              !_detecting &&
              (_detectionResult?.boxes.isNotEmpty ?? false))
            Positioned(
              top: 106,
              left: 16,
              right: 16,
              child: _regionSelectionControls(),
            ),
        ],
      ),
    ),
  );
}
