import 'package:flutter/material.dart';

import '../services/ocr_api_client.dart';

Future<OcrRecognitionOptions?> showOcrSettingsSheet(
  BuildContext context, {
  required OcrRecognitionOptions initial,
}) => showModalBottomSheet<OcrRecognitionOptions>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _OcrSettingsForm(initial: initial),
);

class _OcrSettingsForm extends StatefulWidget {
  const _OcrSettingsForm({required this.initial});

  final OcrRecognitionOptions initial;

  @override
  State<_OcrSettingsForm> createState() => _OcrSettingsFormState();
}

class _OcrSettingsFormState extends State<_OcrSettingsForm> {
  late String _detMode = widget.initial.detMode;
  late String _task = widget.initial.task;
  late int _tokens = widget.initial.maxNewTokens;
  late bool _useLora = widget.initial.useLora;
  late bool _stream = widget.initial.streamResults;
  late final TextEditingController _prompt = TextEditingController(
    text: widget.initial.customPrompt,
  );

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        18 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Recognition settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Choose how the image is detected and read.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _detMode,
              decoration: const InputDecoration(
                labelText: 'Detection engine',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'smart_hybrid',
                  child: Text('Smart Hybrid · automatic layout'),
                ),
                DropdownMenuItem(
                  value: 'standard',
                  child: Text('PP-OCRv4 · standard text'),
                ),
                DropdownMenuItem(
                  value: 'dense',
                  child: Text('PP-OCRv4 · dense small text'),
                ),
                DropdownMenuItem(
                  value: 'pp_doclayout_v2',
                  child: Text('PP-DocLayoutV2 · document blocks'),
                ),
                DropdownMenuItem(
                  value: 'none',
                  child: Text('Full image · no box split'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _detMode = value ?? _detMode),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _task,
              decoration: const InputDecoration(
                labelText: 'Recognition task',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'ocr',
                  child: Text('OCR · text recognition'),
                ),
                DropdownMenuItem(
                  value: 'table',
                  child: Text('Table recognition'),
                ),
                DropdownMenuItem(
                  value: 'formula',
                  child: Text('Formula recognition'),
                ),
                DropdownMenuItem(
                  value: 'chart',
                  child: Text('Chart recognition'),
                ),
                DropdownMenuItem(value: 'custom', child: Text('Custom prompt')),
              ],
              onChanged: (value) => setState(() => _task = value ?? _task),
            ),
            if (_task == 'custom') ...[
              const SizedBox(height: 14),
              TextField(
                controller: _prompt,
                decoration: const InputDecoration(
                  labelText: 'Custom prompt',
                  hintText: 'For example: OCR:',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Text('Maximum tokens')),
                Text('$_tokens'),
              ],
            ),
            Slider(
              value: _tokens.toDouble(),
              min: 128,
              max: 2048,
              divisions: 15,
              label: '$_tokens',
              onChanged: (value) => setState(() => _tokens = value.round()),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use fine-tuned LoRA'),
              value: _useLora,
              onChanged: (value) => setState(() => _useLora = value),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stream results live'),
              subtitle: const Text(
                'Show progress as each selected region is read.',
              ),
              value: _stream,
              onChanged: (value) => setState(() => _stream = value),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                OcrRecognitionOptions(
                  detMode: _detMode,
                  task: _task,
                  customPrompt: _prompt.text.trim().isEmpty
                      ? 'OCR:'
                      : _prompt.text.trim(),
                  maxNewTokens: _tokens,
                  useLora: _useLora,
                  streamResults: _stream,
                ),
              ),
              child: const Text('Apply settings'),
            ),
          ],
        ),
      ),
    ),
  );
}
