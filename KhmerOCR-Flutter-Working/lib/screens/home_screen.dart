import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../widgets/composer.dart';
import '../widgets/app_ui.dart';
import '../widgets/document_list_item.dart';
import '../widgets/message_bubble.dart';
import 'scan_screen.dart';
import 'detail_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import '../theme.dart';
import '../services/firebase_auth_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.state,
    required this.authService,
    required this.user,
  });
  final AppState state;
  final FirebaseAuthService? authService;
  final User? user;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _messageController = TextEditingController();
  final _messageFocusNode = FocusNode();
  final _generalScrollController = ScrollController();
  final List<ChatMessage> _generalMessages = [];
  ChatMessage? _replyingTo;
  ScannedDocument? _pendingAttachment;
  String? _activeGeneralChatId;
  ScannedDocument? _activeDocument;
  bool _generalStreaming = false;
  bool _showDocuments = false;
  bool _showChatHistory = false;
  bool _isComposingNewChat = false;

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
    if (document != null && mounted) {
      setState(() => _pendingAttachment = document);
      _messageFocusNode.requestFocus();
    }
  }

  Future<void> _startDocumentScan(
    BuildContext context, {
    required bool camera,
  }) async {
    final document = await Navigator.of(context).push<ScannedDocument>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          state: state,
          returnToCaller: true,
          openCameraInitially: camera && !kIsWeb,
          openFilePickerInitially: !camera,
          autoExtractOnSelect: true,
        ),
      ),
    );
    if (document != null && mounted) {
      _detail(context, document, isScanResult: true);
    }
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

  void _detail(
    BuildContext context,
    ScannedDocument doc, {
    bool isScanResult = false,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          DetailScreen(document: doc, state: state, isScanResult: isScanResult),
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
            attachment: _documentById(item['attachmentDocumentId'] as String?),
            replyTo: replyTo,
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
      _isComposingNewChat = false;
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
    _isComposingNewChat = true;
    _showDocuments = false;
    _showChatHistory = false;
    _generalMessages.clear();
    _replyingTo = null;
    _pendingAttachment = null;
  });

  void _replyToMessage(ChatMessage message) {
    setState(() => _replyingTo = message);
    _messageFocusNode.requestFocus();
  }

  ScannedDocument? _documentById(String? id) {
    if (id == null) return null;
    for (final document in state.documents) {
      if (document.id == id) return document;
    }
    return null;
  }

  Future<void> _sendMessage() async {
    final question = _messageController.text.trim();
    final attachment = _pendingAttachment;
    if ((question.isEmpty && attachment == null) || _generalStreaming) return;
    final replyTarget = _replyingTo;
    final conversationId =
        _activeGeneralChatId ??
        DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _activeGeneralChatId = conversationId;
      _isComposingNewChat = false;
      if (attachment != null) _activeDocument = attachment;
      _showDocuments = false;
      _showChatHistory = false;
      _generalMessages.add(
        ChatMessage(
          text: question,
          isUser: true,
          attachment: attachment,
          replyTo: replyTarget,
        ),
      );
      _messageController.clear();
      _pendingAttachment = null;
      _replyingTo = null;
      _generalStreaming = true;
    });
    _scrollGeneralToEnd();
    final response = ChatMessage(text: '', isUser: false, streaming: true);
    setState(() => _generalMessages.add(response));
    final prompt = question.isEmpty ? 'Please analyze this image.' : question;
    for (final token in _generalReply(prompt).split(' ')) {
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
                'replyToText': message.replyTo?.text,
                'replyToIsUser': message.replyTo?.isUser,
                'replyToAttachmentDocumentId': message.replyTo?.attachment?.id,
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
    setState(() => _pendingAttachment = document);
    _messageFocusNode.requestFocus();
  }

  void _returnHome() => setState(() {
    _activeGeneralChatId = null;
    _activeDocument = null;
    _isComposingNewChat = false;
    _showDocuments = false;
    _showChatHistory = false;
    _generalMessages.clear();
    _replyingTo = null;
    _pendingAttachment = null;
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final permanentNavigation = constraints.maxWidth >= 1040;
        final sidebar = _ChatHistoryDrawer(
          permanent: permanentNavigation,
          state: state,
          onHome: () {
            if (!permanentNavigation) Navigator.pop(context);
            _returnHome();
          },
          onNewChat: () {
            if (!permanentNavigation) Navigator.pop(context);
            _startNewGeneralChat();
          },
          onScan: () {
            if (!permanentNavigation) Navigator.pop(context);
            _scan(context);
          },
          onDocuments: () {
            if (!permanentNavigation) Navigator.pop(context);
            setState(() {
              _showDocuments = true;
              _showChatHistory = false;
            });
          },
          onChatHistory: () {
            if (!permanentNavigation) Navigator.pop(context);
            setState(() {
              _showDocuments = false;
              _showChatHistory = true;
            });
          },
          onResumeGeneralChat: (id) {
            if (!permanentNavigation) Navigator.pop(context);
            _resumeGeneralChat(id);
          },
          onDocumentChat: (document) {
            if (!permanentNavigation) Navigator.pop(context);
            _chat(context, document);
          },
          onSettings: () {
            if (!permanentNavigation) Navigator.pop(context);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  state: state,
                  authService: widget.authService,
                  user: widget.user,
                ),
              ),
            );
          },
        );

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          drawer: permanentNavigation ? null : sidebar,
          body: SafeArea(
            child: Row(
              children: [
                if (permanentNavigation) ...[
                  SizedBox(width: 280, child: sidebar),
                  VerticalDivider(
                    width: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ],
                Expanded(
                  child: Column(
                    children: [
                      Builder(
                        builder: (scaffoldContext) => _HomeHeader(
                          showMenu: !permanentNavigation,
                          title: _showChatHistory
                              ? 'Chat history'
                              : _showDocuments
                              ? 'Documents'
                              : 'Workspace',
                          onMenu: () =>
                              Scaffold.of(scaffoldContext).openDrawer(),
                          onNewChat: _startNewGeneralChat,
                        ),
                      ),
                      _backgroundOcrCard(),
                      Expanded(
                        child: _showChatHistory
                            ? _ChatHistoryPage(
                                state: state,
                                onGeneralChat: _resumeGeneralChat,
                                onDocumentChat: (document) =>
                                    _chat(context, document),
                              )
                            : _showDocuments
                            ? state.documents.isEmpty
                                  ? _WelcomePanel(onScan: () => _scan(context))
                                  : _RecentDocuments(
                                      documents: state.documents,
                                      onOpen: (doc) => _detail(context, doc),
                                      onChat: (doc) => _chat(context, doc),
                                    )
                            : _isComposingNewChat ||
                                  _activeGeneralChatId != null ||
                                  _generalMessages.isNotEmpty
                            ? _GeneralConversationPanel(
                                messages: _generalMessages,
                                controller: _generalScrollController,
                                onReply: _replyToMessage,
                              )
                            : _LandingPanel(
                                onUpload: () =>
                                    _startDocumentScan(context, camera: false),
                                onCamera: () =>
                                    _startDocumentScan(context, camera: true),
                              ),
                      ),
                      if (!_showChatHistory &&
                          !_showDocuments &&
                          (_isComposingNewChat ||
                              _activeGeneralChatId != null ||
                              _generalMessages.isNotEmpty))
                        _HomeComposer(
                          controller: _messageController,
                          focusNode: _messageFocusNode,
                          replyToText: _replyingTo?.text,
                          onCancelReply: () =>
                              setState(() => _replyingTo = null),
                          attachment: _pendingAttachment,
                          onRemoveAttachment: () => setState(() {
                            _pendingAttachment = null;
                          }),
                          onAddAttachment: _showAttachmentMenu,
                          onSend: _sendMessage,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _backgroundOcrCard() => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final job = state.backgroundOcrJob;
      if (job == null) return const SizedBox.shrink();
      return _BackgroundScanCard(
        job: job,
        onOpen: job.document == null
            ? null
            : () {
                final document = job.document!;
                state.dismissBackgroundOcrJob();
                _detail(context, document, isScanResult: true);
              },
        onDismiss: state.dismissBackgroundOcrJob,
      );
    },
  );
}

class _BackgroundScanCard extends StatelessWidget {
  const _BackgroundScanCard({
    required this.job,
    required this.onOpen,
    required this.onDismiss,
  });

  final BackgroundOcrJob job;
  final VoidCallback? onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final running =
        job.status == BackgroundOcrStatus.preparing ||
        job.status == BackgroundOcrStatus.running;
    final failed = job.status == BackgroundOcrStatus.failed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (running)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        failed
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        color: failed
                            ? Theme.of(context).colorScheme.error
                            : null,
                        size: 21,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        running
                            ? 'Scan running · ${job.name}'
                            : failed
                            ? 'Scan needs attention · ${job.name}'
                            : 'Scan complete · ${job.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (!running)
                      IconButton(
                        onPressed: onDismiss,
                        tooltip: 'Dismiss scan notice',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 19),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 30, top: 3),
                  child: Text(
                    failed
                        ? (job.error ?? 'The scan could not finish.')
                        : job.progressText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (running && job.totalRegions > 0) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: job.currentRegion / job.totalRegions,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ],
                if (onOpen != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 30, top: 5),
                    child: Text(
                      'Tap to view result',
                      style: TextStyle(fontSize: 12),
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

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.showMenu,
    required this.title,
    required this.onMenu,
    required this.onNewChat,
  });

  final bool showMenu;
  final String title;
  final VoidCallback onMenu;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: EdgeInsets.symmetric(horizontal: showMenu ? 12 : 28),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          if (showMenu) ...[
            _HeaderCircleButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Open navigation',
              onPressed: onMenu,
            ),
            const SizedBox(width: 4),
            const AppBrand(),
          ] else
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          const Spacer(),
          _HeaderCircleButton(
            icon: _ComposeGlyph(
              size: 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            tooltip: 'New chat',
            onPressed: onNewChat,
          ),
        ],
      ),
    );
  }
}

class _LandingPanel extends StatelessWidget {
  const _LandingPanel({required this.onUpload, required this.onCamera});

  final VoidCallback onUpload;
  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 660;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 40 : 20,
            vertical: wide ? 56 : 32,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Text(
                      'KHMER + ENGLISH OCR',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'What would you like to read?',
                    style: theme.textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 580),
                    child: Text(
                      'Turn scans, photos, and documents into searchable, selectable text. Your files stay in your local workspace.',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(height: wide ? 32 : 26),
                  if (wide)
                    Row(
                      children: [
                        Expanded(
                          child: _ScanActionCard(
                            icon: Icons.upload_file_outlined,
                            title: 'Upload a document',
                            subtitle: 'PDF, images, Office files, and more',
                            primary: true,
                            onTap: onUpload,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _ScanActionCard(
                            icon: Icons.photo_camera_outlined,
                            title: 'Use your camera',
                            subtitle: 'Capture a page and recognize its text',
                            onTap: onCamera,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    _ScanActionCard(
                      icon: Icons.upload_file_outlined,
                      title: 'Upload a document',
                      subtitle: 'PDF, images, Office files, and more',
                      primary: true,
                      onTap: onUpload,
                    ),
                    const SizedBox(height: 12),
                    _ScanActionCard(
                      icon: Icons.photo_camera_outlined,
                      title: 'Use your camera',
                      subtitle: 'Capture a page and recognize its text',
                      onTap: onCamera,
                    ),
                  ],
                  const SizedBox(height: 28),
                  AppSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.translate_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'អត្ថបទខ្មែរនិង English — readable in light and dark themes.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.65,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScanActionCard extends StatelessWidget {
  const _ScanActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = primary ? AppTheme.accent : theme.colorScheme.onSurface;
    return AppSurface(
      color: primary
          ? AppTheme.accent.withValues(alpha: .055)
          : theme.cardColor,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: primary
                      ? AppTheme.accent
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: primary ? Colors.white : accent,
                  size: 23,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, color: accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
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
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF121925)
          : const Color(0xFFF8FAFC),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      side: BorderSide(color: Theme.of(context).dividerColor),
    ),
    icon: icon,
  );
}

class _ComposeGlyph extends StatelessWidget {
  const _ComposeGlyph({required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _ComposeGlyphPainter(
      color ?? Theme.of(context).colorScheme.onSurface,
    ),
  );
}

class _ComposeGlyphPainter extends CustomPainter {
  const _ComposeGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
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
  bool shouldRepaint(covariant _ComposeGlyphPainter oldDelegate) =>
      color != oldDelegate.color;
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
  Widget build(BuildContext context) {
    return AppPage(
      maxWidth: 900,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ListView(
        children: [
          Text('Documents', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            '${documents.length} saved ${documents.length == 1 ? 'document' : 'documents'} · newest first',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          for (final document in documents)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppSurface(
                child: DocumentListItem(
                  document: document,
                  onTap: () => onOpen(document),
                  onChat: () => onChat(document),
                ),
              ),
            ),
        ],
      ),
    );
  }
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
    required this.attachment,
    required this.onRemoveAttachment,
    required this.onAddAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? replyToText;
  final VoidCallback onCancelReply;
  final ScannedDocument? attachment;
  final VoidCallback onRemoveAttachment;
  final VoidCallback onAddAttachment;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
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
                    color: Theme.of(context).cardColor,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (attachment != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                            child: _AttachmentPreview(
                              document: attachment!,
                              onRemove: onRemoveAttachment,
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          SizedBox.square(
                            dimension: 44,
                            child: Material(
                              color: dark
                                  ? const Color(0xFF242424)
                                  : const Color(0xFFE9E9EC),
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: onAddAttachment,
                                customBorder: const CircleBorder(),
                                child: Center(
                                  child: Icon(
                                    Icons.add_rounded,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              cursorColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              minLines: 1,
                              maxLines: 4,
                              textCapitalization: TextCapitalization.sentences,
                              onSubmitted: (_) => onSend(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontSize: 17,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Ask anything',
                                hintStyle: TextStyle(
                                  color: Theme.of(context).hintColor,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 10,
                                ),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: controller,
                            builder: (context, value, _) {
                              final active =
                                  value.text.trim().isNotEmpty ||
                                  attachment != null;
                              return IconButton(
                                onPressed: active ? onSend : null,
                                tooltip: 'Send message',
                                style: IconButton.styleFrom(
                                  fixedSize: const Size(48, 48),
                                  backgroundColor: active
                                      ? AppTheme.accent
                                      : dark
                                      ? const Color(0xFF252525)
                                      : const Color(0xFFE6E6E8),
                                  foregroundColor: active
                                      ? Colors.white
                                      : dark
                                      ? const Color(0xFF888888)
                                      : const Color(0xFF77777D),
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

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.document, required this.onRemove});

  final ScannedDocument document;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 132,
    height: 132,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: document.imageBytes != null
                ? Image.memory(document.imageBytes!, fit: BoxFit.cover)
                : Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      document.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
          ),
        ),
        Positioned(
          top: 7,
          right: 7,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: const SizedBox(
                width: 30,
                height: 30,
                child: Icon(Icons.close_rounded, color: Colors.white, size: 20),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AttachmentMenu extends StatelessWidget {
  const _AttachmentMenu({required this.onCamera, required this.onUpload});

  final VoidCallback onCamera;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF141414)
          : const Color(0xFFF1F1F3),
      border: Border.all(color: Theme.of(context).dividerColor),
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
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF242424)
                  : const Color(0xFFE6E6E8),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Theme.of(context).colorScheme.onSurface,
              size: 25,
            ),
          ),
          const SizedBox(width: 18),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
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
    required this.permanent,
    required this.state,
    required this.onHome,
    required this.onNewChat,
    required this.onScan,
    required this.onDocuments,
    required this.onChatHistory,
    required this.onResumeGeneralChat,
    required this.onDocumentChat,
    required this.onSettings,
  });

  final bool permanent;
  final AppState state;
  final VoidCallback onHome;
  final VoidCallback onNewChat;
  final VoidCallback onScan;
  final VoidCallback onDocuments;
  final VoidCallback onChatHistory;
  final ValueChanged<String> onResumeGeneralChat;
  final ValueChanged<ScannedDocument> onDocumentChat;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Drawer(
    width: permanent
        ? 280
        : (MediaQuery.sizeOf(context).width * .88)
              .clamp(280.0, 360.0)
              .toDouble(),
    elevation: 0,
    backgroundColor: Theme.of(context).cardColor,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: permanent
          ? BorderRadius.zero
          : const BorderRadius.horizontal(right: Radius.circular(20)),
    ),
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 20),
            child: Row(
              children: [
                const Expanded(child: AppBrand(showTagline: true)),
                IconButton(
                  onPressed: onChatHistory,
                  tooltip: 'Search chat history',
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
          ),
          _SidebarAction(
            icon: Icons.home_outlined,
            title: 'Home',
            onTap: onHome,
          ),
          _SidebarAction(
            icon: Icons.edit_note_rounded,
            title: 'New chat',
            onTap: onNewChat,
          ),
          _SidebarAction(
            icon: Icons.folder_open_outlined,
            title: 'Documents',
            onTap: onDocuments,
          ),
          _SidebarAction(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Chat history',
            onTap: onChatHistory,
          ),
          _SidebarAction(
            icon: Icons.settings_outlined,
            title: 'Settings',
            onTap: onSettings,
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
                    Divider(color: Theme.of(context).dividerColor, height: 1),
                    Padding(
                      padding: EdgeInsets.only(top: 14, bottom: 4),
                      child: Text(
                        'Recent chats',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (visibleRecents.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Your recent chats will appear here.',
                          style: TextStyle(
                            color: Theme.of(context).hintColor,
                            fontSize: 14,
                          ),
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
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${recent.updatedAt.day.toString().padLeft(2, '0')}/'
                                  '${recent.updatedAt.month.toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    color: Theme.of(context).hintColor,
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
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onSurface,
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
                    onPressed: onScan,
                    icon: const Icon(Icons.document_scanner_outlined, size: 21),
                    label: const Text('New scan'),
                  ),
                ),
                const SizedBox(width: 18),
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF242424)
                        : const Color(0xFFE6E6E8),
                    border: Border.fromBorderSide(
                      BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Text(
                    'N',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'Search chat history',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: Theme.of(context).cardColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
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
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView(
                      children: [
                        if (generalChats.isNotEmpty) ...[
                          const _HistorySectionTitle(title: 'Chats'),
                          for (final chat in generalChats)
                            ListTile(
                              leading: const Icon(
                                Icons.chat_bubble_outline_rounded,
                              ),
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
        ),
      ),
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
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
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
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Extract text, explore your files, and get answers from your documents.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 17,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: onScan,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
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
            colors: const [Color(0xFF111827), Color(0xFF475467)],
            icon: Icons.document_scanner_rounded,
            label: 'SCAN',
          ),
          const SizedBox(width: 14),
          _ShowcaseCard(
            size: size,
            angle: 0,
            colors: const [Color(0xFF344054), Color(0xFF98A2B3)],
            icon: Icons.description_rounded,
            label: 'PDF',
          ),
          const SizedBox(width: 14),
          _ShowcaseCard(
            size: size * .9,
            angle: .12,
            colors: const [Color(0xFF1769FF), Color(0xFF67A8FF)],
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
          color: Colors.white,
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
                      color: const Color(0xFFE4E7EC),
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
