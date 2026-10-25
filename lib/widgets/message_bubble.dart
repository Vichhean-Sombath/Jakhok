import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/document.dart';

class ChatMessage {
  ChatMessage({
    required this.text,
    required this.isUser,
    this.streaming = false,
    this.attachment,
    this.replyTo,
  });
  String text;
  final bool isUser;
  bool streaming;
  final ScannedDocument? attachment;
  final ChatMessage? replyTo;
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, this.onReply});
  final ChatMessage message;
  final ValueChanged<ChatMessage>? onReply;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) {
      final imageBytes = message.attachment?.imageBytes;
      if (imageBytes != null) {
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220, maxHeight: 260),
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF242424),
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (message.replyTo != null)
                  _SentReplyQuote(message: message.replyTo!),
                Flexible(
                  child: Image.memory(
                    imageBytes,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(
                          width: 180,
                          height: 180,
                          child: Icon(Icons.broken_image_outlined),
                        ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      final messageText = message.text.isEmpty && message.attachment != null
          ? 'Uploaded ${message.attachment!.name}'
          : message.text;
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 310),
          margin: const EdgeInsets.only(bottom: 18),
          padding: EdgeInsets.all(message.replyTo == null ? 12 : 8),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF333333)
                : const Color(0xFFF2F2F2),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyTo != null)
                _SentReplyQuote(message: message.replyTo!),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  message.replyTo == null ? 4 : 8,
                  message.replyTo == null ? 0 : 2,
                  message.replyTo == null ? 4 : 8,
                  message.replyTo == null ? 0 : 4,
                ),
                child: Text(
                  messageText,
                  style: const TextStyle(fontSize: 16, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3, right: 10),
            child: Icon(Icons.auto_awesome, size: 16),
          ),
          Expanded(
            child: FractionallySizedBox(
              widthFactor: .82,
              alignment: Alignment.topLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AssistantText(
                    text: message.text,
                    streaming: message.streaming,
                  ),
                  if (!message.streaming && message.text.trim().isNotEmpty)
                    Wrap(
                      spacing: 0,
                      children: [
                        _MessageAction(
                          label: 'Reply',
                          onPressed: onReply == null
                              ? null
                              : () => onReply!(message),
                        ),
                        _MessageAction(
                          label: 'Copy',
                          onPressed: () => _copyMessage(context, message.text),
                        ),
                        _MessageAction(
                          label: 'Download',
                          onPressed: () =>
                              _downloadMessage(context, message.text),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyMessage(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _downloadMessage(BuildContext context, String text) async {
    final extension = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose file type'),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DownloadFormatOption(
              label: 'Text file (.txt)',
              onTap: () => Navigator.pop(dialogContext, 'txt'),
            ),
            _DownloadFormatOption(
              label: 'JSON file (.json)',
              onTap: () => Navigator.pop(dialogContext, 'json'),
            ),
            _DownloadFormatOption(
              label: 'Markdown file (.md)',
              onTap: () => Navigator.pop(dialogContext, 'md'),
            ),
          ],
        ),
      ),
    );
    if (extension == null || !context.mounted) return;

    final contents = extension == 'json'
        ? const JsonEncoder.withIndent('  ').convert({'response': text})
        : text;
    final mimeType = switch (extension) {
      'json' => 'application/json',
      'md' => 'text/markdown',
      _ => 'text/plain',
    };
    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Download response',
      fileName: 'Jakhok_response.$extension',
      mimeType: mimeType,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: Uint8List.fromList(utf8.encode(contents)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          savedPath == null ? 'Download cancelled' : 'Response downloaded',
        ),
      ),
    );
  }
}

class _DownloadFormatOption extends StatelessWidget {
  const _DownloadFormatOption({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    onTap: onTap,
  );
}

class _MessageAction extends StatelessWidget {
  const _MessageAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    ),
    child: Text(label, style: const TextStyle(fontSize: 13)),
  );
}

class _SentReplyQuote extends StatelessWidget {
  const _SentReplyQuote({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final excerpt = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = excerpt.isNotEmpty
        ? excerpt
        : message.attachment == null
        ? 'Message'
        : 'Image · ${message.attachment!.name}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Replied to',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.text, required this.streaming});
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final parts = text.split('```');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < parts.length; i++)
          if (i.isEven)
            Align(
              alignment: Alignment.centerLeft,
              child: MarkdownBody(
                data: parts[i],
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: const TextStyle(fontSize: 16, height: 1.55),
                      h1: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                      h2: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                      listBullet: const TextStyle(fontSize: 16),
                    ),
              ),
            )
          else
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF262626)
                    : const Color(0xFFF7F7F7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                parts[i].replaceFirst(RegExp(r'^\w+\n'), ''),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
        if (streaming)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('▍', style: TextStyle(fontSize: 16)),
          ),
      ],
    );
  }
}
