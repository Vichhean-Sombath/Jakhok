import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/document.dart';
import 'chat_screen.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.document, required this.state});
  final ScannedDocument document;
  final AppState state;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'share', child: Text('Copy text')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        if (document.imagePath.isNotEmpty &&
            File(document.imagePath).existsSync())
          GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog.fullscreen(
                backgroundColor: Colors.black,
                child: Stack(
                  children: [
                    Center(
                      child: InteractiveViewer(
                        child: Image.file(
                          File(document.imagePath),
                          fit: BoxFit.contain,
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
              child: Image.file(
                File(document.imagePath),
                height: 190,
                fit: BoxFit.cover,
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
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Text copied')));
              },
              icon: const Icon(Icons.copy_outlined, size: 19),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF262626)
                : const Color(0xFFF7F7F7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            document.text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ),
        if (document.text.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'No text was extracted from this file.',
              style: TextStyle(color: Color(0xFF8E8E8E)),
            ),
          ),
      ],
    ),
    bottomNavigationBar: document.text.isNotEmpty
        ? SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatScreen(document: document, state: state),
                  ),
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Chat with this Document'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  foregroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          )
        : null,
  );
}
