import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../theme.dart';
import '../widgets/detection_image_view.dart';
import '../widgets/app_ui.dart';
import '../widgets/ocr_text_display.dart';
import 'chat_screen.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({
    super.key,
    required this.document,
    required this.state,
    this.isScanResult = false,
  });
  final ScannedDocument document;
  final AppState state;
  final bool isScanResult;

  @override
  Widget build(BuildContext context) {
    final imageProvider = _documentImageProvider();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          document.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'delete') {
                await state.deleteDocument(document);
                if (context.mounted) Navigator.pop(context);
              } else if (value == 'share') {
                await Clipboard.setData(ClipboardData(text: document.text));
                if (context.mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Extracted text copied')),
                  );
              } else if (value == 'download') {
                await _downloadDocument(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'share', child: Text('Copy text')),
              PopupMenuItem(value: 'download', child: Text('Download')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: AppPage(
        maxWidth: 960,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 110),
          children: [
            if (imageProvider != null)
              GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog.fullscreen(
                    backgroundColor: Colors.black,
                    child: Stack(
                      children: [
                        Center(
                          child: InteractiveViewer(
                            child: SizedBox(
                              width: MediaQuery.sizeOf(context).width,
                              height: MediaQuery.sizeOf(context).height,
                              child: DetectionImageView(
                                imageProvider: imageProvider,
                                imageSize: document.imageSize,
                                boxes: document.detectionBoxes,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 22,
                          right: 14,
                          child: IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).width >= 900 ? 320 : 210,
                    width: double.infinity,
                    child: DetectionImageView(
                      imageProvider: imageProvider,
                      imageSize: document.imageSize,
                      boxes: document.detectionBoxes,
                    ),
                  ),
                ),
              ),
            if (document.detectionError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 18),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Text-region preview unavailable: ${document.detectionError}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (document.imageSize != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  document.detectionBoxes.isEmpty
                      ? 'No text regions detected'
                      : '${document.detectionBoxes.length} text region${document.detectionBoxes.length == 1 ? '' : 's'} detected',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Extracted text',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy text',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: document.text));
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Text copied')),
                      );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 19),
                ),
              ],
            ),
            AppSurface(
              padding: const EdgeInsets.all(20),
              child: OcrTextDisplay(text: document.text),
            ),
            if (document.text.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No text was extracted from this file.',
                  style: TextStyle(color: Color(0xFF8E8E8E)),
                ),
              ),
            if (isScanResult) ...[
              const SizedBox(height: 24),
              const Text(
                'Would you like to chat about this result?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: document.text.isNotEmpty
          ? SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: isScanResult
                        ? Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.pop(context),
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(52),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: const Text('No, thanks'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        document: document,
                                        state: state,
                                        showExtractedText: true,
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(Icons.chat_bubble_outline),
                                  label: const Text('Yes, chat'),
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(52),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : FilledButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  document: document,
                                  state: state,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Chat with this Document'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              backgroundColor: AppTheme.accent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  ImageProvider<Object>? _documentImageProvider() {
    if (document.imagePath.isNotEmpty &&
        File(document.imagePath).existsSync()) {
      return FileImage(File(document.imagePath));
    }
    final bytes = document.imageBytes;
    return bytes == null ? null : MemoryImage(bytes);
  }

  Future<void> _downloadDocument(BuildContext context) async {
    final extension = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose file type'),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Text file (.txt)'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              onTap: () => Navigator.pop(dialogContext, 'txt'),
            ),
            ListTile(
              title: const Text('JSON file (.json)'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              onTap: () => Navigator.pop(dialogContext, 'json'),
            ),
            ListTile(
              title: const Text('Markdown file (.md)'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              onTap: () => Navigator.pop(dialogContext, 'md'),
            ),
          ],
        ),
      ),
    );
    if (extension == null || !context.mounted) return;

    final baseName = document.name
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim();
    final contents = extension == 'json'
        ? const JsonEncoder.withIndent(
            '  ',
          ).convert({'document': document.name, 'text': document.text})
        : document.text;
    final mimeType = switch (extension) {
      'json' => 'application/json',
      'md' => 'text/markdown',
      _ => 'text/plain',
    };
    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Download document text',
      fileName: '${baseName.isEmpty ? 'Netra_document' : baseName}.$extension',
      mimeType: mimeType,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: Uint8List.fromList(utf8.encode(contents)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          savedPath == null ? 'Download cancelled' : 'Document downloaded',
        ),
      ),
    );
  }
}
