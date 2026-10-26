import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../theme.dart';
import '../widgets/composer.dart';
import '../widgets/message_bubble.dart';
import 'scan_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.document,
    this.conversationId,
    required this.state,
    this.initialQuestion,
    this.showExtractedText = false,
  });
  final ScannedDocument? document;
  final String? conversationId;
  final AppState state;
  final String? initialQuestion;
  final bool showExtractedText;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _composerFocusNode = FocusNode();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  final List<ScannedDocument> _attachedDocuments = [];
  ChatMessage? _replyingTo;
  bool _deepThink = false;
  bool _search = false;
  bool _streaming = false;
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  String get _conversationId => widget.document?.id ?? widget.conversationId!;
  String get _historyKey => AppState.chatHistoryKey(_conversationId);

  ScannedDocument? _documentById(String? id) {
    if (id == null) return null;
    for (final document in widget.state.documents) {
      if (document.id == id) return document;
    }
    return null;
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw != null) {
        final rows = jsonDecode(raw) as List<dynamic>;
        _messages
          ..clear()
          ..addAll(
            rows.map((row) {
              final item = row as Map<String, dynamic>;
              final replyText = item['replyToText'] as String?;
              final replyAttachmentId =
                  item['replyToAttachmentDocumentId'] as String?;
              final replyTo = replyText == null && replyAttachmentId == null
                  ? null
                  : ChatMessage(
                      text: replyText ?? '',
                      isUser: item['replyToIsUser'] as bool? ?? false,
                      attachment: _documentById(replyAttachmentId),
                    );
              return ChatMessage(
                text: item['text'] as String,
                isUser: item['isUser'] as bool,
                attachment: _documentById(
                  item['attachmentDocumentId'] as String?,
                ),
                replyTo: replyTo,
                isExtractedText:
                    item['isExtractedText'] as bool? ??
                    looksLikeExtractedTextMessage(item['text'] as String),
              );
            }),
          );
      }
    } catch (_) {
      _messages.clear();
    }
    final isNewConversation = _messages.isEmpty;
    if (isNewConversation) {
      _addWelcomeMessage();
      final document = widget.document;
      if (widget.showExtractedText && document != null) {
        _messages.add(
          ChatMessage(
            text: document.text,
            isUser: false,
            isExtractedText: true,
          ),
        );
      }
    }
    if (mounted) {
      setState(() => _loadingHistory = false);
      final initialQuestion = widget.initialQuestion?.trim();
      if (initialQuestion != null && initialQuestion.isNotEmpty) {
        await _send(initialQuestion);
      } else if (isNewConversation && widget.showExtractedText) {
        await _saveHistory();
      }
    }
  }

  void _addWelcomeMessage() => _messages.add(
    ChatMessage(
      text: widget.document == null
          ? 'Hi! What would you like to talk about?'
          : 'I’ve read **${widget.document!.name}**. What would you like to know about it?',
      isUser: false,
    ),
  );

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(
        _messages
            .map(
              (message) => {
                'text': message.text,
                'isUser': message.isUser,
                'isExtractedText': message.isExtractedText,
                'attachmentDocumentId': message.attachment?.id,
                'replyToText': message.replyTo?.text,
                'replyToIsUser': message.replyTo?.isUser,
                'replyToAttachmentDocumentId': message.replyTo?.attachment?.id,
              },
            )
            .toList(),
      ),
    );
    if (_messages.any((message) => message.isUser)) {
      if (widget.document != null) {
        widget.state.markChatHistory(widget.document!.id);
      } else {
        final firstQuestion = _messages.firstWhere((message) => message.isUser);
        final title = firstQuestion.text.length > 42
            ? '${firstQuestion.text.substring(0, 39)}…'
            : firstQuestion.text;
        await widget.state.saveGeneralChat(_conversationId, title);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _composerFocusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _replyToMessage(ChatMessage message) {
    setState(() => _replyingTo = message);
    _composerFocusNode.requestFocus();
  }

  Future<void> _send([String? preset]) async {
    final question = (preset ?? _controller.text).trim();
    if (question.isEmpty || _streaming) return;
    final replyTarget = _replyingTo;
    setState(() {
      _messages.add(
        ChatMessage(text: question, isUser: true, replyTo: replyTarget),
      );
      _controller.clear();
      _replyingTo = null;
      _streaming = true;
    });
    _scrollToEnd();
    final response = _mockAnswer(question);
    final assistant = ChatMessage(text: '', isUser: false, streaming: true);
    setState(() => _messages.add(assistant));
    for (final token in response.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 48));
      if (!mounted) return;
      setState(() => assistant.text += '$token ');
      _scrollToEnd();
    }
    if (mounted)
      setState(() {
        assistant.streaming = false;
        _streaming = false;
      });
    await _saveHistory();
  }

  String _mockAnswer(String question) {
    final documents = [
      if (widget.document != null) widget.document!,
      ..._attachedDocuments,
    ];
    final text = documents
        .map((document) => '${document.name}\n${document.text}')
        .join('\n\n');
    if (text.trim().isEmpty) {
      final prefix = _search
          ? 'Search mode is selected. '
          : _deepThink
          ? 'DeepThink mode is selected. '
          : '';
      return '${prefix}This is a local chat preview. Connect an AI service to generate answers to general questions. You said: “$question”';
    }
    final excerpt = text.length > 320 ? '${text.substring(0, 320)}…' : text;
    final lower = question.toLowerCase();
    if (lower.contains('summar'))
      return 'Here’s a concise summary of the scanned document:\n\n$excerpt\n\nThis is a local preview response. Connect an AI service to generate a semantic summary.';
    if (lower.contains('key point'))
      return 'Key points found in the extracted text:\n\n$excerpt\n\nThis local preview uses the document text directly.';
    if (lower.contains('translate'))
      return 'Translation is not connected in this preview. The extracted text is available below for a future translation service:\n\n```text\n$excerpt\n```';
    final prefix = _search
        ? 'Search mode is selected. '
        : _deepThink
        ? 'DeepThink mode is selected. '
        : '';
    return '${prefix}This chat is running with a mock response, so no network request was made. Here is the extracted text for reference:\n\n```text\n$excerpt\n```';
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients)
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 180,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
  });

  void _newChat() {
    if (widget.document == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            state: widget.state,
            conversationId: DateTime.now().microsecondsSinceEpoch.toString(),
          ),
        ),
      );
      return;
    }
    _attachedDocuments.clear();
    setState(() {
      _replyingTo = null;
      _messages..clear();
      _addWelcomeMessage();
    });
    _saveHistory();
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add to this chat',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Scan new document'),
              onTap: () => Navigator.pop(context, 'scan'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Select existing document'),
              onTap: () => Navigator.pop(context, 'existing'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'existing') {
      final docs = widget.state.documents
          .where((doc) => doc.id != widget.document?.id)
          .toList();
      if (docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('There are no other saved documents yet.'),
          ),
        );
      } else {
        final selected = await showModalBottomSheet<ScannedDocument>(
          context: context,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Select a document',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final doc in docs)
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(doc.name),
                    onTap: () => Navigator.pop(context, doc),
                  ),
              ],
            ),
          ),
        );
        if (selected != null && mounted) _appendDocument(selected);
      }
    } else {
      final added = await Navigator.of(context).push<ScannedDocument>(
        MaterialPageRoute(
          builder: (_) => ScanScreen(
            state: widget.state,
            returnToCaller: true,
            openGalleryInitially: choice == 'gallery',
          ),
        ),
      );
      if (added != null && mounted) _appendDocument(added);
    }
  }

  void _appendDocument(ScannedDocument doc) {
    if (doc.id != widget.document?.id &&
        !_attachedDocuments.any((attached) => attached.id == doc.id)) {
      _attachedDocuments.add(doc);
    }
    setState(
      () => _messages.add(
        ChatMessage(
          text: 'Added document: ${doc.name}\n\n${doc.text}',
          isUser: false,
        ),
      ),
    );
    _saveHistory();
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    appBar: AppBar(
      leading: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.arrow_back),
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Chat', style: TextStyle(fontSize: 16)),
          if (widget.document != null)
            Text(
              widget.document!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF8E8E8E),
                fontSize: 11,
                fontWeight: FontWeight.normal,
              ),
            ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _newChat,
          tooltip: 'New chat',
          icon: const Icon(Icons.add, size: 26),
        ),
      ],
    ),
    body: Column(
      children: [
        Expanded(
          child: _messages.length == 1
              ? _emptyChat()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 22, 16, 20),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) => MessageBubble(
                    message: _messages[index],
                    onReply: _replyToMessage,
                  ),
                ),
        ),
        if (_loadingHistory)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        Composer(
          controller: _controller,
          focusNode: _composerFocusNode,
          replyToText: _replyingTo?.text,
          onCancelReply: () => setState(() => _replyingTo = null),
          hintText: widget.document == null
              ? 'Message'
              : 'Ask about this document…',
          showModes: widget.document != null,
          deepThink: _deepThink,
          search: _search,
          onDeepThink: () => setState(() => _deepThink = !_deepThink),
          onSearch: () => setState(() => _search = !_search),
          onAttach: _attach,
          onSend: () => _send(),
          enabled: !_streaming && !_loadingHistory,
        ),
      ],
    ),
  );

  Widget _emptyChat() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 52, 20, 20),
    children: [
      const Center(child: Icon(Icons.auto_awesome, size: 25)),
      const SizedBox(height: 13),
      const Center(
        child: Text(
          'Ask anything about your document',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 25),
      for (final prompt
          in widget.document == null
              ? [
                  'Help me brainstorm an idea',
                  'Explain a topic simply',
                  'Draft a short message',
                ]
              : [
                  'Summarize this document',
                  'What are the key points?',
                  'Translate to Spanish',
                ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton(
            onPressed: _streaming ? null : () => _send(prompt),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
              side: BorderSide(color: Theme.of(context).dividerColor),
              foregroundColor: Theme.of(context).textTheme.bodyLarge?.color,
            ),
            child: Text(prompt),
          ),
        ),
      const SizedBox(height: 12),
      Text(
        'Preview replies are generated locally. No AI service is connected.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: AppTheme.secondary),
      ),
    ],
  );
}
