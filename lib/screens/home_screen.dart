import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../widgets/document_list_item.dart';
import '../widgets/message_bubble.dart';
import 'scan_screen.dart';
import 'detail_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import '../theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _messageController = TextEditingController();
  final _generalScrollController = ScrollController();
  final List<ChatMessage> _generalMessages = [];
  String? _activeGeneralChatId;
  ScannedDocument? _activeDocument;
  bool _generalStreaming = false;

  AppState get state => widget.state;

  @override
  void dispose() {
    _messageController.dispose();
    _generalScrollController.dispose();
    super.dispose();
  }

  Future<void> _scan(BuildContext context) async {
    final document = await Navigator.of(
      context,
    ).push<ScannedDocument>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(state: state, returnToCaller: true),
      ),
    );
    if (document != null && mounted) await _showDocumentResult(document);
  }

  void _detail(BuildContext context, ScannedDocument doc) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DetailScreen(document: doc, state: state),
        ),
      );

  void _chat(
    BuildContext context,
    ScannedDocument doc, {
    String? question,
    bool showExtractedText = false,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            document: doc,
            state: state,
            initialQuestion: question,
            showExtractedText: showExtractedText,
          ),
        ),
      );

  Future<void> _resumeGeneralChat(String id) async {
    final prefs = await SharedPreferences.getInstance();
    List<ChatMessage> messages = [];
    ScannedDocument? activeDocument;
    final documentId = prefs.getString('chat_document_$id');
    if (documentId != null) {
      for (final document in state.documents) {
        if (document.id == documentId) {
          activeDocument = document;
          break;
        }
      }
    }
    try {
      final raw = prefs.getString(AppState.chatHistoryKey(id));
      if (raw != null) {
        messages = (jsonDecode(raw) as List<dynamic>).map((row) {
          final item = row as Map<String, dynamic>;
          return ChatMessage(
            text: item['text'] as String,
            isUser: item['isUser'] as bool,
          );
        }).toList();
      }
    } catch (_) {
      messages = [];
    }
    if (messages.isEmpty) {
      messages.add(
        ChatMessage(
          text: 'Hi! What would you like to talk about?',
          isUser: false,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _activeGeneralChatId = id;
      _activeDocument = activeDocument;
      _generalMessages
        ..clear()
        ..addAll(messages);
    });
    _scrollGeneralToEnd();
  }

  void _startNewGeneralChat() => setState(() {
    _activeGeneralChatId = null;
    _activeDocument = null;
    _generalMessages.clear();
  });

  Future<void> _sendMessage() async {
    final question = _messageController.text.trim();
    if (question.isEmpty || _generalStreaming) return;
    final conversationId =
        _activeGeneralChatId ??
        DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _activeGeneralChatId = conversationId;
      _generalMessages.add(ChatMessage(text: question, isUser: true));
      _messageController.clear();
      _generalStreaming = true;
    });
    _scrollGeneralToEnd();
    final response = ChatMessage(text: '', isUser: false, streaming: true);
    setState(() => _generalMessages.add(response));
    for (final token in _generalReply(question).split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      if (!mounted) return;
      setState(() => response.text += '$token ');
      _scrollGeneralToEnd();
    }
    if (!mounted) return;
    setState(() {
      response.streaming = false;
      _generalStreaming = false;
    });
    await _saveGeneralChat(conversationId);
  }

  String _generalReply(String question) {
    final document = _activeDocument;
    if (document == null) {
      return 'This is a local chat preview. Connect an AI service to generate answers to general questions. You said: “$question”';
    }
    final excerpt = document.text.length > 320
        ? '${document.text.substring(0, 320)}…'
        : document.text;
    return 'This is a local chat preview, so an AI service is not connected yet. '
        'I can reference the text extracted from **${document.name}**:\n\n'
        '```text\n$excerpt\n```';
  }

  Future<void> _saveGeneralChat(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final document = _activeDocument;
    if (document != null) {
      await prefs.setString('chat_document_$id', document.id);
    }
    await prefs.setString(
      AppState.chatHistoryKey(id),
      jsonEncode(
        _generalMessages
            .where((message) => !message.streaming)
            .map((message) => {'text': message.text, 'isUser': message.isUser})
            .toList(),
      ),
    );
    final firstQuestion = _generalMessages.firstWhere(
      (message) => message.isUser,
    );
    final title = firstQuestion.text.length > 42
        ? '${firstQuestion.text.substring(0, 39)}…'
        : firstQuestion.text;
    await state.saveGeneralChat(id, title);
  }

  void _scrollGeneralToEnd() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_generalScrollController.hasClients) {
          _generalScrollController.animateTo(
            _generalScrollController.position.maxScrollExtent + 160,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });

  Future<void> _uploadFile() async {
    final document = await Navigator.of(context).push<ScannedDocument>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          state: state,
          returnToCaller: true,
          openFilePickerInitially: true,
        ),
      ),
    );
    if (document == null || !mounted) return;
    await _showDocumentResult(document);
  }

  Future<void> _showDocumentResult(ScannedDocument document) async {
    final conversationId =
        _activeGeneralChatId ??
        DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _activeGeneralChatId = conversationId;
      _activeDocument = document;
      _generalMessages.add(
        ChatMessage(text: 'Uploaded **${document.name}**', isUser: true),
      );
      _generalMessages.add(
        ChatMessage(
          text:
              'Here’s the text I extracted from **${document.name}**:\n\n'
              '```text\n${document.text}\n```',
          isUser: false,
        ),
      );
    });
    _scrollGeneralToEnd();
    await _saveGeneralChat(conversationId);
    if (_messageController.text.trim().isNotEmpty && mounted) {
      await _sendMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: Colors.black,
      colorScheme: ColorScheme.dark(
        primary: AppTheme.accent,
        secondary: AppTheme.accent,
        surface: Color(0xFF171717),
      ),
      dividerColor: const Color(0xFF292929),
      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
    );
    return Theme(
      data: darkTheme,
      child: Scaffold(
        backgroundColor: Colors.black,
        drawer: _ChatHistoryDrawer(
          state: state,
          onChat: (document) {
            Navigator.pop(context);
            _chat(context, document);
          },
          onGeneralChat: (id) {
            Navigator.pop(context);
            _resumeGeneralChat(id);
          },
          onScan: () {
            Navigator.pop(context);
            _scan(context);
          },
          onUpload: () {
            Navigator.pop(context);
            _uploadFile();
          },
          onNewChat: () {
            Navigator.pop(context);
            _startNewGeneralChat();
          },
          onSettings: () {
            Navigator.pop(context);
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsScreen(state: state)),
            );
          },
        ),
        body: SafeArea(
          child: Column(
            children: [
              Builder(
                builder: (scaffoldContext) => _HomeHeader(
                  onMenu: () => Scaffold.of(scaffoldContext).openDrawer(),
                  onScan: () => _scan(context),
                ),
              ),
              Expanded(
                child:
                    _activeGeneralChatId != null || _generalMessages.isNotEmpty
                    ? _GeneralConversationPanel(
                        messages: _generalMessages,
                        controller: _generalScrollController,
                      )
                    : state.documents.isEmpty
                    ? _WelcomePanel(onScan: () => _scan(context))
                    : _RecentDocuments(
                        documents: state.documents,
                        onOpen: (doc) => _detail(context, doc),
                        onChat: (doc) => _chat(context, doc),
                      ),
              ),
              _HomeComposer(
                controller: _messageController,
                onUpload: _uploadFile,
                onScan: () => _scan(context),
                onSend: _sendMessage,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onMenu, required this.onScan});
  final VoidCallback onMenu;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(
      children: [
        _HeaderCircleButton(
          icon: Icons.menu_rounded,
          tooltip: 'Chat history',
          onPressed: onMenu,
        ),
        const Spacer(),
        _HeaderCircleButton(
          icon: Icons.document_scanner_outlined,
          tooltip: 'Scan a document',
          onPressed: onScan,
        ),
      ],
    ),
  );
}

class _HeaderCircleButton extends StatelessWidget {
  const _HeaderCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    style: IconButton.styleFrom(
      fixedSize: const Size(54, 54),
      backgroundColor: const Color(0xFF171717),
      foregroundColor: Colors.white,
      side: const BorderSide(color: Color(0xFF2A2A2A)),
    ),
    icon: Icon(icon, size: 25),
  );
}

class _RecentDocuments extends StatelessWidget {
  const _RecentDocuments({
    required this.documents,
    required this.onOpen,
    required this.onChat,
  });
  final List<ScannedDocument> documents;
  final ValueChanged<ScannedDocument> onOpen;
  final ValueChanged<ScannedDocument> onChat;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Text(
          'RECENT DOCUMENTS',
          style: TextStyle(
            color: Color(0xFF8E8E8E),
            fontSize: 12,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      for (var i = 0; i < documents.length; i++) ...[
        DocumentListItem(
          document: documents[i],
          onTap: () => onOpen(documents[i]),
          onChat: () => onChat(documents[i]),
        ),
        if (i != documents.length - 1) const Divider(height: 1, indent: 72),
      ],
    ],
  );
}

class _GeneralConversationPanel extends StatelessWidget {
  const _GeneralConversationPanel({
    required this.messages,
    required this.controller,
  });

  final List<ChatMessage> messages;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 20),
        itemCount: messages.length,
        itemBuilder: (context, index) =>
            MessageBubble(message: messages[index]),
      ),
    ),
  );
}

class _HomeComposer extends StatelessWidget {
  const _HomeComposer({
    required this.controller,
    required this.onUpload,
    required this.onScan,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoidCallback onUpload;
  final VoidCallback onScan;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                border: Border.all(color: const Color(0xFF292929)),
                borderRadius: BorderRadius.circular(34),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onUpload,
                    tooltip: 'Upload a document',
                    style: IconButton.styleFrom(
                      fixedSize: const Size(44, 44),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.add_rounded, size: 34),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => onSend(),
                      style: const TextStyle(color: Colors.white, fontSize: 17),
                      decoration: const InputDecoration(
                        hintText: 'Ask anything',
                        hintStyle: TextStyle(color: Color(0xFF858585)),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onScan,
                    tooltip: 'Scan a document',
                    style: IconButton.styleFrom(
                      fixedSize: const Size(44, 44),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.camera_alt_rounded, size: 24),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final active = value.text.trim().isNotEmpty;
                      return IconButton(
                        onPressed: active ? onSend : null,
                        tooltip: 'Send message',
                        style: IconButton.styleFrom(
                          fixedSize: const Size(48, 48),
                          backgroundColor: active
                              ? AppTheme.accent
                              : const Color(0xFF252525),
                          foregroundColor: active
                              ? Colors.white
                              : const Color(0xFF888888),
                        ),
                        icon: const Icon(Icons.arrow_upward_rounded, size: 25),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatHistoryDrawer extends StatefulWidget {
  const _ChatHistoryDrawer({
    required this.state,
    required this.onChat,
    required this.onGeneralChat,
    required this.onScan,
    required this.onUpload,
    required this.onNewChat,
    required this.onSettings,
  });

  final AppState state;
  final ValueChanged<ScannedDocument> onChat;
  final ValueChanged<String> onGeneralChat;
  final VoidCallback onScan;
  final VoidCallback onUpload;
  final VoidCallback onNewChat;
  final VoidCallback onSettings;

  @override
  State<_ChatHistoryDrawer> createState() => _ChatHistoryDrawerState();
}

class _ChatHistoryDrawerState extends State<_ChatHistoryDrawer> {
  final _searchController = TextEditingController();
  bool _searching = false;
  bool _showAll = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final generalChats = widget.state.generalChatHistory
        .where((chat) => chat.title.toLowerCase().contains(query))
        .toList();
    final chats = widget.state.chatHistory
        .where((document) => document.name.toLowerCase().contains(query))
        .toList();
    final totalChats = generalChats.length + chats.length;
    final visibleGeneralChats = _showAll
        ? generalChats
        : generalChats.take(5).toList();
    final remainingSlots = (5 - visibleGeneralChats.length).clamp(0, 5);
    final visibleDocumentChats = _showAll
        ? chats
        : chats.take(remainingSlots).toList();
    return Drawer(
      width: MediaQuery.sizeOf(context).width * .8,
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 18, 22),
              child: Row(
                children: [
                  Expanded(
                    child: _searching
                        ? TextField(
                            controller: _searchController,
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              hintText: 'Search chats',
                              hintStyle: TextStyle(color: Color(0xFF888888)),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          )
                        : const Text(
                            'Khmer OCR',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _searchController.clear();
                    }),
                    tooltip: _searching ? 'Close search' : 'Search chats',
                    icon: Icon(
                      _searching ? Icons.close_rounded : Icons.search_rounded,
                      size: 29,
                    ),
                    style: IconButton.styleFrom(foregroundColor: Colors.white),
                  ),
                ],
              ),
            ),
            _SidebarAction(
              icon: Icons.document_scanner_outlined,
              title: 'Scan document',
              onTap: widget.onScan,
            ),
            _SidebarAction(
              icon: Icons.menu_book_outlined,
              title: 'Library',
              onTap: () => Navigator.pop(context),
            ),
            _SidebarAction(
              icon: Icons.attach_file_rounded,
              title: 'Upload file',
              onTap: widget.onUpload,
            ),
            _SidebarAction(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Chat history',
              onTap: () => setState(() => _showAll = true),
            ),
            _SidebarAction(
              icon: Icons.settings_outlined,
              title: 'Settings',
              onTap: widget.onSettings,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 14, 24, 10),
              child: Divider(color: Color(0xFF303030), height: 1),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Recent chats',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Expanded(
              child: totalChats == 0
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(26),
                        child: Text(
                          'Your chats will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF888888),
                            height: 1.5,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      children: [
                        for (final chat in visibleGeneralChats)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 3,
                            ),
                            title: Text(
                              chat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                            onTap: () => widget.onGeneralChat(chat.id),
                          ),
                        for (final document in visibleDocumentChats)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 3,
                            ),
                            title: Text(
                              document.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                            onTap: () => widget.onChat(document),
                          ),
                      ],
                    ),
            ),
            if (!_showAll && totalChats > 5)
              TextButton(
                onPressed: () => setState(() => _showAll = true),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF999999),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                child: const Text('See all…', style: TextStyle(fontSize: 16)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.onNewChat,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.edit_square, size: 24),
                      label: const Text(
                        'Chat',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF242424),
                      border: Border.fromBorderSide(
                        BorderSide(color: Color(0xFF383838)),
                      ),
                    ),
                    child: const Text(
                      'KO',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarAction extends StatelessWidget {
  const _SidebarAction({
    required this.icon,
    required this.title,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Icon(icon, size: 27, color: Colors.white),
            const SizedBox(width: 18),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
      ),
    ),
  );
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.onScan});
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, _) => Column(
      children: [
        const Spacer(),
        const _DocumentShowcase(),
        const SizedBox(height: 42),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Document scanning, made simple',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Extract text, explore your files, and get answers from your documents.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFAAAAAA),
              fontSize: 17,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: onScan,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF202020),
            foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFF303030)),
            padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 17),
          ),
          child: const Text(
            'Try it',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const Spacer(),
      ],
    ),
  );
}

class _DocumentShowcase extends StatelessWidget {
  const _DocumentShowcase();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, _) {
      final width = MediaQuery.sizeOf(context).width;
      final size = ((width - 88) / 3).clamp(82.0, 132.0);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ShowcaseCard(
            size: size * .9,
            angle: -.12,
            colors: const [Color(0xFF60425D), Color(0xFFB27462)],
            icon: Icons.document_scanner_rounded,
            label: 'SCAN',
          ),
          const SizedBox(width: 14),
          _ShowcaseCard(
            size: size,
            angle: 0,
            colors: const [Color(0xFF7A64B8), Color(0xFFB8A5EC)],
            icon: Icons.description_rounded,
            label: 'PDF',
          ),
          const SizedBox(width: 14),
          _ShowcaseCard(
            size: size * .9,
            angle: .12,
            colors: const [Color(0xFF2065BB), Color(0xFF68B3E8)],
            icon: Icons.text_snippet_rounded,
            label: 'TEXT',
          ),
        ],
      );
    },
  );
}

class _ShowcaseCard extends StatelessWidget {
  const _ShowcaseCard({
    required this.size,
    required this.angle,
    required this.colors,
    required this.icon,
    required this.label,
  });

  final double size;
  final double angle;
  final List<Color> colors;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: angle,
    child: Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: colors.first.withOpacity(.28),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F5FC),
          borderRadius: BorderRadius.circular(15),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: colors.first),
                const Spacer(),
                Text(
                  label,
                  style: TextStyle(
                    color: colors.first,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                  ),
                ),
              ],
            ),
            const Spacer(),
            for (final fraction in [.9, .68, .82, .52])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDBD9E2),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
