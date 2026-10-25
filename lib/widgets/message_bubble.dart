import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/document.dart';

class ChatMessage {
  ChatMessage({
    required this.text,
    required this.isUser,
    this.streaming = false,
    this.attachment,
  });
  String text;
  final bool isUser;
  bool streaming;
  final ScannedDocument? attachment;
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
            child: Image.memory(
              imageBytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const SizedBox(
                width: 180,
                height: 180,
                child: Icon(Icons.broken_image_outlined),
              ),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF333333)
                : const Color(0xFFF2F2F2),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            messageText,
            style: const TextStyle(fontSize: 16, height: 1.45),
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
                    TextButton(
                      onPressed: onReply == null ? null : () => onReply!(message),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white60,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Reply', style: TextStyle(fontSize: 13)),
                    ),
                ],
              ),
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
