import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  static const _panel = Color(0xFF1D1D1F);
  static const _muted = Color(0xFF9A9AA0);

  Color _panelColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? _panel
      : const Color(0xFFF1F1F3);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
                    color: Theme.of(context).colorScheme.onSurface,
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
                    value: kIsWeb ? 'Khmer + English' : 'Latin (mobile)',
                    onTap: () => _showInfo(
                      context,
                      'OCR language',
                      kIsWeb
                          ? 'Web image OCR recognizes Khmer and English. Android and iOS currently use the Latin-only ML Kit recognizer.'
                          : 'Android and iOS currently use the Latin-only ML Kit recognizer. Khmer recognition needs a Khmer-capable mobile OCR model.',
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
                    icon: Icons.dark_mode_outlined,
                    title: 'Dark mode',
                    trailing: Switch.adaptive(
                      value: state.isDark,
                      activeTrackColor: AppTheme.accent,
                      onChanged: (value) => state.setDarkMode(value),
                    ),
                    onTap: () => state.setDarkMode(!state.isDark),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const _SectionHeading('App settings'),
              const SizedBox(height: 12),
              _SettingsCard(
                children: [
                  _SettingRow(
                    icon: Icons.info_outline_rounded,
                    title: 'About Jakhok',
                    onTap: () => _showAbout(context),
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
                backgroundColor: _panelColor(context),
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                side: BorderSide(color: Theme.of(context).dividerColor),
              ),
              icon: const Icon(Icons.close_rounded, size: 30),
            ),
          ),
        ],
      ),
    ),
  );

  void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panelColor(context),
        title: Text(
          title,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
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

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final dark = theme.brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: _panelColor(dialogContext),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Jakhok',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xFF303034)
                        : const Color(0xFFE5E5E9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Version 1.0.0',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'A simple place to scan documents, read files, and ask questions about your content.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showLicensePage(
                  context: context,
                  applicationName: 'Jakhok',
                  applicationVersion: '1.0.0',
                );
              },
              child: const Text('Licenses'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1D1D1F)
          : const Color(0xFFF1F1F3),
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
        style: TextStyle(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFFB8B8BD)
              : const Color(0xFF66666D),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 60, right: 18),
    child: Divider(height: 1, color: Theme.of(context).dividerColor),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    this.value,
    this.trailing,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? value;
  final Widget? trailing;
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
            Icon(
              icon,
              color: Theme.of(context).colorScheme.onSurface,
              size: 26,
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 16,
                ),
              ),
            ),
            if (trailing != null)
              trailing!
            else ...[
              if (value != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 160,
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: Color(0xFF9A9AA0),
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: const Color(0xFF77777D),
                size: 23,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
