import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../widgets/composer.dart';
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
  final _messageFocusNode = FocusNode();
  final _generalScrollController = ScrollController();
  final List<ChatMessage> _generalMessages = [];
  ChatMessage? _replyingTo;
  String? _activeGeneralChatId;
  ScannedDocument? _activeDocument;
  bool _generalStreaming = false;
  bool _showDocuments = false;
  bool _showChatHistory = false;

  AppState get state => widget.state;

  @override
  void dispose() {
    _messageController.dispose();
    _messageFocusNode.dispose();
    _generalScrollController.dispose();
    super.dispose();
  }

  Future<void> _scan(BuildContext context) async {
    final document = await Navigator.of(context).push<ScannedDocument>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          state: state,
          returnToCaller: true,
          openCameraInitially: !kIsWeb,
        ),
      ),
    );
    if (document != null && mounted) await _showDocumentResult(document);
  }

  Future<void> _showAttachmentMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (_, constraints) => SizedBox(
            width: constraints.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: SizedBox(
                    width: (constraints.maxWidth - 36)
                        .clamp(0.0, 520.0)
                        .toDouble(),
                    child: _AttachmentMenu(
                      onCamera: () {
                        Navigator.pop(sheetContext);
                        _scan(context);
                      },
                      onUpload: () {
                        Navigator.pop(sheetContext);
                        _uploadFile();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
  }) => Navigator.of(context).push(
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
          final attachmentId = item['attachmentDocumentId'] as String?;
          ScannedDocument? attachment;
          if (attachmentId != null) {
            for (final document in state.documents) {
              if (document.id == attachmentId) {
                attachment = document;
                break;
              }
            }
          }
          return ChatMessage(
            text: item['text'] as String,
            isUser: item['isUser'] as bool,
            attachment: attachment,
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
      _showDocuments = false;
      _showChatHistory = false;
      _replyingTo = null;
      _generalMessages
        ..clear()
        ..addAll(messages);
    });
    _scrollGeneralToEnd();
  }

  void _startNewGeneralChat() => setState(() {
    _activeGeneralChatId = null;
    _activeDocument = null;
    _showDocuments = false;
    _showChatHistory = false;
    _generalMessages.clear();
    _replyingTo = null;
  });

  void _replyToMessage(ChatMessage message) {
    setState(() => _replyingTo = message);
    _messageFocusNode.requestFocus();
  }

  Future<void> _sendMessage() async {
    final question = _messageController.text.trim();
    if (question.isEmpty || _generalStreaming) return;
    final conversationId =
        _activeGeneralChatId ??
        DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _activeGeneralChatId = conversationId;
      _showDocuments = false;
      _showChatHistory = false;
      _generalMessages.add(ChatMessage(text: question, isUser: true));
      _messageController.clear();
      _replyingTo = null;
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
            .map(
              (message) => {
                'text': message.text,
                'isUser': message.isUser,
                'attachmentDocumentId': message.attachment?.id,
              },
            )
            .toList(),
      ),
    );
    final firstQuestion = _generalMessages.firstWhere(
      (message) => message.isUser && message.text.trim().isNotEmpty,
      orElse: () => _generalMessages.firstWhere((message) => message.isUser),
    );
    final questionText = firstQuestion.text.trim();
    final title = questionText.isEmpty
        ? firstQuestion.attachment?.name ?? 'Document chat'
        : questionText.length > 42
        ? '${questionText.substring(0, 39)}…'
        : questionText;
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
      _showDocuments = false;
      _showChatHistory = false;
      _generalMessages.add(
        ChatMessage(text: '', isUser: true, attachment: document),
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
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.white,
      ),
      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
        fontFamily: 'KhmerOSSiemReap',
      ),
    );
    return Theme(
      data: darkTheme,
      child: Scaffold(
        backgroundColor: Colors.black,
        drawer: _ChatHistoryDrawer(
          state: state,
          onScan: () {
            Navigator.pop(context);
            _scan(context);
          },
          onDocuments: () {
            Navigator.pop(context);
            setState(() {
              _showDocuments = true;
              _showChatHistory = false;
            });
          },
          onChatHistory: () {
            Navigator.pop(context);
            setState(() {
              _showDocuments = false;
              _showChatHistory = true;
            });
          },
          onNewChat: () {
            Navigator.pop(context);
            _startNewGeneralChat();
          },
          onResumeGeneralChat: (id) {
            Navigator.pop(context);
            _resumeGeneralChat(id);
          },
          onDocumentChat: (document) {
            Navigator.pop(context);
            _chat(context, document);
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
                  onNewChat: _startNewGeneralChat,
                ),
              ),
              Expanded(
                child: _showChatHistory
                    ? _ChatHistoryPage(
                        state: state,
                        onGeneralChat: _resumeGeneralChat,
                        onDocumentChat: (document) => _chat(context, document),
                      )
                    : _showDocuments
                    ? state.documents.isEmpty
                          ? _WelcomePanel(onScan: () => _scan(context))
                          : _RecentDocuments(
                              documents: state.documents,
                              onOpen: (doc) => _detail(context, doc),
                              onChat: (doc) => _chat(context, doc),
                            )
                    : _activeGeneralChatId != null ||
                          _generalMessages.isNotEmpty
                    ? _GeneralConversationPanel(
                        messages: _generalMessages,
                        controller: _generalScrollController,
                        onReply: _replyToMessage,
                      )
                    : _WelcomePanel(onScan: () => _scan(context)),
              ),
              if (!_showChatHistory)
                _HomeComposer(
                  controller: _messageController,
                  focusNode: _messageFocusNode,
                  replyToText: _replyingTo?.text,
                  onCancelReply: () => setState(() => _replyingTo = null),
                  onAddAttachment: _showAttachmentMenu,
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
  const _HomeHeader({required this.onMenu, required this.onNewChat});
  final VoidCallback onMenu;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(
      children: [
        _HeaderCircleButton(
          icon: const Icon(Icons.menu_rounded, size: 25),
          tooltip: 'Chat history',
          onPressed: onMenu,
        ),
        const Spacer(),
        _HeaderCircleButton(
          icon: const _ComposeGlyph(size: 24),
          tooltip: 'New chat',
          onPressed: onNewChat,
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
  final Widget icon;
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
    icon: icon,
  );
}

class _ComposeGlyph extends StatelessWidget {
  const _ComposeGlyph({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _ComposeGlyphPainter());
}

class _ComposeGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final outline = Path()
      ..moveTo(13, 3.5)
      ..lineTo(5.8, 3.5)
      ..quadraticBezierTo(3.5, 3.5, 3.5, 5.8)
      ..lineTo(3.5, 18.2)
      ..quadraticBezierTo(3.5, 20.5, 5.8, 20.5)
      ..lineTo(18.2, 20.5)
      ..quadraticBezierTo(20.5, 20.5, 20.5, 18.2)
      ..lineTo(20.5, 12.5);
    canvas.drawPath(outline, paint);

    final pencil = Path()
      ..moveTo(7.1, 16.9)
      ..lineTo(8.2, 12.8)
      ..lineTo(17.4, 3.6)
      ..quadraticBezierTo(18.6, 2.4, 19.8, 3.6)
      ..lineTo(20.8, 4.6)
      ..quadraticBezierTo(22, 5.8, 20.8, 7)
      ..lineTo(11.6, 16.2)
      ..lineTo(7.1, 16.9)
      ..close();
    canvas.drawPath(pencil, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    required this.onReply,
  });

  final List<ChatMessage> messages;
  final ScrollController controller;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 20),
        itemCount: messages.length,
        itemBuilder: (context, index) =>
            MessageBubble(message: messages[index], onReply: onReply),
      ),
    ),
  );
}

class _HomeComposer extends StatelessWidget {
  const _HomeComposer({
    required this.controller,
    required this.focusNode,
    required this.replyToText,
    required this.onCancelReply,
    required this.onAddAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? replyToText;
  final VoidCallback onCancelReply;
  final VoidCallback onAddAttachment;
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyToText != null)
                  ReplyContextPreview(
                    message: replyToText!,
                    onCancel: onCancelReply,
                  ),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111111),
                    border: Border.all(color: const Color(0xFF292929)),
                    borderRadius: BorderRadius.circular(34),
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 44,
                        child: Material(
                          color: const Color(0xFF242424),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: onAddAttachment,
                            customBorder: const CircleBorder(),
                            child: const Center(
                              child: Icon(
                                Icons.add_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: controller,
                              focusNode: focusNode,
                              cursorColor: Colors.white,
                              minLines: 1,
                              maxLines: 4,
                              textCapitalization: TextCapitalization.sentences,
                              onSubmitted: (_) => onSend(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                              ),
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
                          ],
                        ),
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
                            icon: const Icon(
                              Icons.arrow_upward_rounded,
                              size: 25,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentMenu extends StatelessWidget {
  const _AttachmentMenu({required this.onCamera, required this.onUpload});

  final VoidCallback onCamera;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
    decoration: BoxDecoration(
      color: const Color(0xFF141414),
      border: Border.all(color: const Color(0xFF303030)),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AttachmentMenuItem(
          icon: Icons.photo_camera_outlined,
          label: 'Camera',
          onTap: onCamera,
        ),
        _AttachmentMenuItem(
          icon: Icons.attach_file_rounded,
          label: 'Upload',
          onTap: onUpload,
        ),
      ],
    ),
  );
}

class _AttachmentMenuItem extends StatelessWidget {
  const _AttachmentMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0xFF242424),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 25),
          ),
          const SizedBox(width: 18),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChatHistoryDrawer extends StatelessWidget {
  const _ChatHistoryDrawer({
    required this.state,
    required this.onScan,
    required this.onDocuments,
    required this.onChatHistory,
    required this.onNewChat,
    required this.onResumeGeneralChat,
    required this.onDocumentChat,
    required this.onSettings,
  });

  final AppState state;
  final VoidCallback onScan;
  final VoidCallback onDocuments;
  final VoidCallback onChatHistory;
  final VoidCallback onNewChat;
  final ValueChanged<String> onResumeGeneralChat;
  final ValueChanged<ScannedDocument> onDocumentChat;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Drawer(
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
                const Expanded(
                  child: Text(
                    'Jakhok',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onChatHistory,
                  tooltip: 'Search chat history',
                  icon: const Icon(Icons.search_rounded, size: 29),
                  style: IconButton.styleFrom(foregroundColor: Colors.white),
                ),
              ],
            ),
          ),
          _SidebarAction(
            icon: Icons.document_scanner_outlined,
            title: 'Scan Document',
            onTap: onScan,
          ),
          _SidebarAction(
            icon: Icons.folder_open_outlined,
            title: 'Document',
            onTap: onDocuments,
            customIcon: const _FolderOutlineGlyph(size: 27),
          ),
          _SidebarAction(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Chat History',
            onTap: onChatHistory,
            customIcon: const _ChatBubbleOutlineGlyph(size: 27),
          ),
          _SidebarAction(
            icon: Icons.settings_outlined,
            title: 'Setting',
            onTap: onSettings,
            customIcon: const _SettingsOutlineGlyph(size: 27),
          ),
          Expanded(
            child: Builder(
              builder: (context) {
                final recents = <_SidebarRecentItem>[
                  ...state.generalChatHistory.map(
                    (chat) => _SidebarRecentItem(
                      title: chat.title,
                      updatedAt: chat.updatedAt,
                      onTap: () => onResumeGeneralChat(chat.id),
                    ),
                  ),
                  ...state.chatHistory.map(
                    (document) => _SidebarRecentItem(
                      title: document.name,
                      updatedAt: document.createdAt,
                      onTap: () => onDocumentChat(document),
                    ),
                  ),
                ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                final visibleRecents = recents.take(8).toList();

                return ListView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 18, 12),
                  children: [
                    const Divider(color: Color(0xFF303030), height: 1),
                    const Padding(
                      padding: EdgeInsets.only(top: 14, bottom: 4),
                      child: Text(
                        'Recent chats',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (visibleRecents.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Your recent chats will appear here.',
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      )
                    else
                      ...visibleRecents.map(
                        (recent) => InkWell(
                          onTap: recent.onTap,
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    recent.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${recent.updatedAt.day.toString().padLeft(2, '0')}/'
                                  '${recent.updatedAt.month.toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (recents.length > visibleRecents.length)
                      TextButton(
                        onPressed: onChatHistory,
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          foregroundColor: Colors.white60,
                        ),
                        child: const Text('See all…'),
                      ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onNewChat,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: const StadiumBorder(),
                    ),
                    icon: const _ComposeGlyph(size: 24),
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

class _SidebarRecentItem {
  const _SidebarRecentItem({
    required this.title,
    required this.updatedAt,
    required this.onTap,
  });

  final String title;
  final DateTime updatedAt;
  final VoidCallback onTap;
}

class _ChatHistoryPage extends StatefulWidget {
  const _ChatHistoryPage({
    required this.state,
    required this.onGeneralChat,
    required this.onDocumentChat,
  });

  final AppState state;
  final ValueChanged<String> onGeneralChat;
  final ValueChanged<ScannedDocument> onDocumentChat;

  @override
  State<_ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<_ChatHistoryPage> {
  final _searchController = TextEditingController();

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
    final documentChats = widget.state.chatHistory
        .where((document) => document.name.toLowerCase().contains(query))
        .toList();
    final hasChats = generalChats.isNotEmpty || documentChats.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search chat history',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: const Color(0xFF171717),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: const BorderSide(color: Color(0xFF303030)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: const BorderSide(color: Color(0xFF303030)),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 18, 24, 8),
          child: Text(
            'Chat History',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: !hasChats
              ? Center(
                  child: Text(
                    query.isEmpty
                        ? 'Your chats will appear here.'
                        : 'No matching chats found.',
                    style: const TextStyle(color: Color(0xFF888888)),
                  ),
                )
              : ListView(
                  children: [
                    if (generalChats.isNotEmpty) ...[
                      const _HistorySectionTitle(title: 'Chats'),
                      for (final chat in generalChats)
                        ListTile(
                          leading: const _ChatBubbleOutlineGlyph(size: 24),
                          title: Text(
                            chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_dateLabel(chat.updatedAt)),
                          onTap: () => widget.onGeneralChat(chat.id),
                        ),
                    ],
                    if (documentChats.isNotEmpty) ...[
                      const _HistorySectionTitle(title: 'Document chats'),
                      for (final document in documentChats)
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            document.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_dateLabel(document.createdAt)),
                          onTap: () => widget.onDocumentChat(document),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  String _dateLabel(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class _HistorySectionTitle extends StatelessWidget {
  const _HistorySectionTitle({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
    child: Text(
      title,
      style: const TextStyle(
        color: Color(0xFF929292),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SidebarAction extends StatelessWidget {
  const _SidebarAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.customIcon,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Widget? customIcon;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            customIcon ?? Icon(icon, size: 27, color: Colors.white),
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

class _FolderOutlineGlyph extends StatelessWidget {
  const _FolderOutlineGlyph({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _FolderOutlinePainter());
}

class _FolderOutlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final folder = Path()
      ..moveTo(20, 20)
      ..quadraticBezierTo(22, 20, 22, 18)
      ..lineTo(22, 8)
      ..quadraticBezierTo(22, 6, 20, 6)
      ..lineTo(12.2, 6)
      ..quadraticBezierTo(11, 6, 10.3, 5)
      ..lineTo(9.6, 4)
      ..quadraticBezierTo(8.9, 3, 7.7, 3)
      ..lineTo(4, 3)
      ..quadraticBezierTo(2, 3, 2, 5)
      ..lineTo(2, 18)
      ..quadraticBezierTo(2, 20, 4, 20)
      ..close();
    canvas.drawPath(folder, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SettingsOutlineGlyph extends StatelessWidget {
  const _SettingsOutlineGlyph({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _SettingsOutlinePainter());
}

class _SettingsOutlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final points = <Offset>[];
    for (var tooth = 0; tooth < 6; tooth++) {
      final center = -90 + tooth * 60;
      for (final point in const [
        (-18.0, 7.6),
        (-12.0, 9.8),
        (12.0, 9.8),
        (18.0, 7.6),
      ]) {
        final angle = (center + point.$1) * 3.141592653589793 / 180;
        points.add(
          Offset(
            12 + point.$2 * math.cos(angle),
            12 + point.$2 * math.sin(angle),
          ),
        );
      }
    }
    final gear = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      gear.lineTo(point.dx, point.dy);
    }
    gear.close();
    canvas.drawPath(gear, paint);
    canvas.drawCircle(const Offset(12, 12), 3.2, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ChatBubbleOutlineGlyph extends StatelessWidget {
  const _ChatBubbleOutlineGlyph({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _ChatBubbleOutlinePainter(),
  );
}

class _ChatBubbleOutlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final bubble = Path()
      ..moveTo(7, 4)
      ..lineTo(17, 4)
      ..quadraticBezierTo(21, 4, 21, 8)
      ..lineTo(21, 13.5)
      ..quadraticBezierTo(21, 17.5, 17, 17.5)
      ..lineTo(10, 17.5)
      ..lineTo(5.5, 20.8)
      ..quadraticBezierTo(4.8, 21.3, 5.1, 20.4)
      ..lineTo(6, 17.1)
      ..quadraticBezierTo(3, 16.5, 3, 13.5)
      ..lineTo(3, 8)
      ..quadraticBezierTo(3, 4, 7, 4)
      ..close();
    canvas.drawPath(bubble, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
            minimumSize: const Size(0, 42),
          ),
          child: const Text(
            'Try it',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
