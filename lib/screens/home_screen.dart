import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/document.dart';
import '../widgets/document_list_item.dart';
import 'scan_screen.dart';
import 'detail_screen.dart';
import 'chat_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  Future<void> _scan(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ScanScreen(state: state)));
  }

  void _detail(BuildContext context, ScannedDocument doc) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DetailScreen(document: doc, state: state),
        ),
      );

  void _chat(BuildContext context, ScannedDocument doc) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(document: doc, state: state),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        icon: const Icon(Icons.menu),
        onPressed: () => _showMenu(context),
      ),
      title: const Text('Documents'),
      actions: [
        IconButton(
          tooltip: 'New scan',
          onPressed: () => _scan(context),
          icon: const Icon(Icons.add, size: 27),
        ),
        const SizedBox(width: 4),
      ],
    ),
    body: state.documents.isEmpty
        ? _EmptyState(onScan: () => _scan(context))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  'RECENTS',
                  style: TextStyle(
                    color: Color(0xFF8E8E8E),
                    fontSize: 12,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: state.documents.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final doc = state.documents[index];
                    return DocumentListItem(
                      document: doc,
                      onTap: () => _detail(context, doc),
                      onChat: () => _chat(context, doc),
                    );
                  },
                ),
              ),
            ],
          ),
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    floatingActionButton: state.documents.isEmpty
        ? null
        : FloatingActionButton.extended(
            onPressed: () => _scan(context),
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Scan Document'),
          ),
  );

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(
            state.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          ),
          title: Text(state.isDark ? 'Light appearance' : 'Dark appearance'),
          onTap: () {
            Navigator.pop(context);
            state.toggleTheme();
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onScan});
  final VoidCallback onScan;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF292929)
                  : const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Icon(Icons.document_scanner_outlined, size: 42),
          ),
          const SizedBox(height: 22),
          const Text(
            'Scan your first document',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Capture a page to extract its text and ask questions about it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8E8E8E), height: 1.45),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Scan Document'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(190, 48),
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : Colors.black,
              foregroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Colors.black
                  : Colors.white,
            ),
          ),
        ],
      ),
    ),
  );
}
