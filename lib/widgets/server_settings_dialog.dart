import 'package:flutter/material.dart';

/// Dialog allowing users to dynamically configure the Central Bank server base URL.
class ServerSettingsDialog extends StatefulWidget {
  final String initialUrl;

  const ServerSettingsDialog({
    super.key,
    required this.initialUrl,
  });

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSave() {
    var rawUrl = _controller.text.trim();
    while (rawUrl.endsWith('/')) {
      rawUrl = rawUrl.substring(0, rawUrl.length - 1);
    }

    if (!rawUrl.startsWith('http://') && !rawUrl.startsWith('https://')) {
      setState(() {
        _errorText = 'URL must start with http:// or https://';
      });
      return;
    }

    Navigator.pop(context, rawUrl);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Central Bank Server URL'),
      content: TextField(
        key: const Key('server_url_input'),
        controller: _controller,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: 'Server URL',
          hintText: 'e.g., https://airbirr-api.vercel.app',
          border: const OutlineInputBorder(),
          errorText: _errorText,
        ),
      ),
      actions: [
        TextButton(
          key: const Key('server_url_cancel_button'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('server_url_save_button'),
          onPressed: _onSave,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
