import 'package:flutter/material.dart';

import '../theme.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.deepThink,
    required this.search,
    required this.onDeepThink,
    required this.onSearch,
    required this.onAttach,
    required this.onSend,
    required this.enabled,
  });
  final TextEditingController controller;
  final bool deepThink;
  final bool search;
  final VoidCallback onDeepThink;
  final VoidCallback onSearch;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF232323) : Colors.white,
            border: Border.all(
              color: dark ? const Color(0xFF3A3A3A) : AppTheme.border,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _ModeChip(
                    icon: Icons.psychology_outlined,
                    title: 'DeepThink',
                    active: deepThink,
                    onTap: onDeepThink,
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    icon: Icons.public,
                    title: 'Search',
                    active: search,
                    onTap: onSearch,
                  ),
                ],
              ),
              TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) {
                  if (controller.text.trim().isNotEmpty && enabled) onSend();
                },
                decoration: const InputDecoration(
                  hintText: 'Ask about this document…',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                  isDense: true,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: onAttach,
                    icon: const Icon(Icons.attach_file, size: 21),
                    tooltip: 'Attach document',
                  ),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final active = value.text.trim().isNotEmpty && enabled;
                      return IconButton(
                        onPressed: active ? onSend : null,
                        tooltip: 'Send',
                        style: IconButton.styleFrom(
                          backgroundColor: active
                              ? (dark ? Colors.white : Colors.black)
                              : (dark
                                    ? const Color(0xFF414141)
                                    : const Color(0xFFE5E5E5)),
                          foregroundColor: active
                              ? (dark ? Colors.black : Colors.white)
                              : const Color(0xFF8E8E8E),
                        ),
                        icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.icon,
    required this.title,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(20),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: active ? AppTheme.accent.withOpacity(.12) : Colors.transparent,
        border: Border.all(
          color: active ? AppTheme.accent : Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: active ? AppTheme.accent : const Color(0xFF8E8E8E),
          ),
          const SizedBox(width: 5),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: active ? AppTheme.accent : const Color(0xFF8E8E8E),
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    ),
  );
}
