import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/sms_row.dart';
import 'services/csv_parser.dart';
import 'services/sms_service.dart';

void main() {
  runApp(const SmsBulkSenderApp());
}

class SmsBulkSenderApp extends StatelessWidget {
  const SmsBulkSenderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SMS Bulk Sender',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF315C4C),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const SenderScreen(),
    );
  }
}

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final _parser = const SmsCsvParser();
  final _smsService = const SmsService();
  final _delayController = TextEditingController(text: '2');

  List<SmsRow> _rows = [];
  String? _fileName;
  String? _error;
  bool _isSending = false;
  bool _cancelRequested = false;

  @override
  void dispose() {
    _delayController.dispose();
    super.dispose();
  }

  Future<void> _pickCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: true,
    );
    if (result == null || !mounted) return;

    try {
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        throw const FormatException('Could not read the selected file.');
      }
      final parsed = _parser.parse(utf8.decode(bytes));
      setState(() {
        _rows = parsed;
        _fileName = file.name;
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() {
        _rows = [];
        _fileName = null;
        _error = error.message;
      });
    } on UnicodeDecodeError {
      setState(() {
        _rows = [];
        _fileName = null;
        _error = 'The CSV must be UTF-8 encoded.';
      });
    }
  }

  double? _validatedDelay() {
    final delay = double.tryParse(_delayController.text.trim());
    if (delay == null || delay < 0 || delay > 3600) {
      setState(() {
        _error = 'Delay must be a number from 0 to 3600 seconds.';
      });
      return null;
    }
    return delay;
  }

  Future<void> _startSending() async {
    final delaySeconds = _validatedDelay();
    if (delaySeconds == null || _rows.isEmpty) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Send all messages?'),
            content: Text(
              'This will send ${_rows.length} text messages from this phone '
              'with a $delaySeconds second delay between each one.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Send'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      final allowed = await _smsService.requestPermission();
      if (!allowed) {
        setState(() {
          _error = 'SMS permission was denied. Enable it in Android settings.';
        });
        return;
      }
    } on PlatformException catch (error) {
      setState(() {
        _error = error.message ?? 'Could not request SMS permission.';
      });
      return;
    }
    if (!mounted) return;

    setState(() {
      _isSending = true;
      _cancelRequested = false;
      _error = null;
      for (final row in _rows) {
        row.status = SmsRowStatus.pending;
        row.error = null;
      }
    });

    for (var index = 0; index < _rows.length; index++) {
      if (_cancelRequested) break;
      final row = _rows[index];
      setState(() => row.status = SmsRowStatus.sending);
      try {
        await _smsService.send(
          phoneNumber: row.phoneNumber,
          message: row.message,
        );
        if (!mounted) return;
        setState(() => row.status = SmsRowStatus.sent);
      } on PlatformException catch (error) {
        if (!mounted) return;
        setState(() {
          row.status = SmsRowStatus.failed;
          row.error = error.message ?? error.code;
        });
      }

      if (index < _rows.length - 1 &&
          !_cancelRequested &&
          delaySeconds > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: (delaySeconds * 1000).round()),
        );
        if (!mounted) return;
      }
    }

    if (mounted) {
      setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _rows.where((row) => row.status == SmsRowStatus.sent).length;
    final failed = _rows
        .where((row) => row.status == SmsRowStatus.failed)
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('SMS Bulk Sender')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _fileName == null
                        ? 'Choose a CSV with headers: phone number,message'
                        : '$_fileName · ${_rows.length} messages',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSending ? null : _pickCsv,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Import CSV'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: _delayController,
                          enabled: !_isSending,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Delay (sec)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_rows.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('Sent $sent · Failed $failed · Total ${_rows.length}'),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _rows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No CSV loaded.\nMessages are reviewed here before sending.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = _rows[index];
                        return ListTile(
                          leading: _StatusIcon(status: row.status),
                          title: Text(row.phoneNumber),
                          subtitle: Text(
                            row.error == null
                                ? row.message
                                : '${row.message}\n${row.error}',
                          ),
                          isThreeLine: row.error != null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: _isSending
            ? OutlinedButton.icon(
                onPressed: () => setState(() => _cancelRequested = true),
                icon: const Icon(Icons.stop),
                label: Text(_cancelRequested ? 'Stopping…' : 'Stop'),
              )
            : FilledButton.icon(
                onPressed: _rows.isEmpty ? null : _startSending,
                icon: const Icon(Icons.send),
                label: Text('Send ${_rows.length} messages'),
              ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final SmsRowStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      SmsRowStatus.pending => const Icon(Icons.schedule),
      SmsRowStatus.sending => const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      SmsRowStatus.sent => const Icon(Icons.check_circle, color: Colors.green),
      SmsRowStatus.failed => Icon(
        Icons.error,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}
