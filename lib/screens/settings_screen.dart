import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  static const _panel = Color(0xFF1D1D1F);
  static const _separator = Color(0xFF39393B);
  static const _muted = Color(0xFF9A9AA0);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 68, 22),
                child: Text(
                  'Settings',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingsCard(
                children: [
                  _SettingRow(
                    icon: Icons.folder_open_outlined,
                    title: 'Workspace',
                    value: 'On this device',
                    onTap: () => _showInfo(
                      context,
                      'Local workspace',
                      'Your scanned documents and extracted text are saved on this device.',
                    ),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.document_scanner_outlined,
                    title: 'OCR language',
                    value: 'Latin',
                    onTap: () => _showInfo(
                      context,
                      'OCR language',
                      'Text recognition currently uses the Latin model. Khmer recognition needs a Khmer capable on-device model.',
                    ),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.description_outlined,
                    title: 'Documents',
                    value: '${state.documents.length}',
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const _SectionHeading('Theme'),
              const SizedBox(height: 12),
              _SettingsCard(
                children: [
                  _SettingRow(
                    icon: Icons.nightlight_outlined,
                    title: 'Appearance',
                    value: state.isDark ? 'Dark' : 'Light',
                    showSelector: true,
                    onTap: () => _chooseAppearance(context),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.palette_outlined,
                    title: 'Accent color',
                    value: _accentName(AppTheme.accent),
                    valueColor: AppTheme.accent,
                    showSelector: true,
                    onTap: () => _chooseAccent(context),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const _SectionHeading('App settings'),
              const SizedBox(height: 12),
              _SettingsCard(
                children: [
                  _SettingRow(
                    icon: Icons.settings_outlined,
                    title: 'General',
                    onTap: () => _showInfo(
                      context,
                      'General',
                      'Khmer OCR is an offline first document scanner with local text extraction and chat previews.',
                    ),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.notifications_none_rounded,
                    title: 'Notifications',
                    onTap: () => _showInfo(
                      context,
                      'Notifications',
                      'There are no notifications configured for this app.',
                    ),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.storage_outlined,
                    title: 'Storage and privacy',
                    onTap: () => _showInfo(
                      context,
                      'Storage and privacy',
                      'Documents, extracted text, and chat previews are stored locally. No document is sent to a server by this preview app.',
                    ),
                  ),
                  _SettingDivider(),
                  _SettingRow(
                    icon: Icons.info_outline_rounded,
                    title: 'About Khmer OCR',
                    onTap: () => showAboutDialog(
                      context: context,
                      applicationName: 'Khmer OCR',
                      applicationVersion: '1.0.0',
                      applicationIcon: const Icon(Icons.document_scanner),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 8,
            right: 16,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: 'Close settings',
              style: IconButton.styleFrom(
                fixedSize: const Size(54, 54),
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF383838)),
              ),
              icon: const Icon(Icons.close_rounded, size: 30),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _chooseAppearance(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetTitle('Appearance'),
            _ChoiceTile(
              title: 'Dark',
              selected: state.isDark,
              onTap: () async {
                await state.setDarkMode(true);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            _ChoiceTile(
              title: 'Light',
              selected: !state.isDark,
              onTap: () async {
                await state.setDarkMode(false);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseAccent(BuildContext context) async {
    const colors = <String, Color>{
      'Blue': Color(0xFF3563F5),
      'Purple': Color(0xFF9B6DFF),
      'Teal': Color(0xFF25B8A6),
      'Orange': Color(0xFFFF934D),
    };
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetTitle('Accent color'),
            for (final entry in colors.entries)
              _ChoiceTile(
                title: entry.key,
                color: entry.value,
                selected: AppTheme.accent.value == entry.value.value,
                onTap: () async {
                  await state.setAccentColor(entry.value);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: _muted, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  String _accentName(Color color) {
    if (color.value == const Color(0xFF9B6DFF).value) return 'Purple';
    if (color.value == const Color(0xFF25B8A6).value) return 'Teal';
    if (color.value == const Color(0xFFFF934D).value) return 'Orange';
    return 'Blue';
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF1D1D1F),
      borderRadius: BorderRadius.circular(28),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFB8B8BD),
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _SettingDivider extends StatelessWidget {
  const _SettingDivider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: 60, right: 18),
    child: Divider(height: 1, color: Color(0xFF39393B)),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    this.value,
    this.valueColor,
    this.showSelector = false,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? value;
  final Color? valueColor;
  final bool showSelector;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(26),
    child: SizedBox(
      height: 78,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              if (valueColor != null) ...[
                Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    color: valueColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9A9AA0),
                    fontSize: 16,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Icon(
              showSelector ? Icons.unfold_more_rounded : Icons.chevron_right,
              color: const Color(0xFF77777D),
              size: 23,
            ),
          ],
        ),
      ),
    ),
  );
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.selected,
    required this.onTap,
    this.color,
  });
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: color == null
        ? null
        : Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
    title: Text(title, style: const TextStyle(color: Colors.white)),
    trailing: selected
        ? const Icon(Icons.check_rounded, color: Colors.white)
        : null,
  );
}
