import 'dart:async';
import 'dart:convert';

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
  final _delayController = TextEditingController(text: '10');

  List<SmsRow> _rows = [];
  StreamSubscription<SmsStatusEvent>? _statusSubscription;
  String? _fileName;
  String? _error;
  bool _isSending = false;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _statusSubscription = _smsService.statusEvents.listen(
      _handleStatusEvent,
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = 'SMS status listener failed: $error';
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _delayController.dispose();
    super.dispose();
  }

  void _handleStatusEvent(SmsStatusEvent event) {
    final index = _rows.indexWhere((row) => row.messageId == event.messageId);
    if (index == -1 || !mounted) return;
    final row = _rows[index];
    setState(() {
      switch (event.status) {
        case 'delivered':
          row.status = SmsRowStatus.delivered;
          row.statusDetail = 'Recipient delivery confirmed';
          row.error = null;
        case 'deliveryUnconfirmed':
          row.status = SmsRowStatus.deliveryUnconfirmed;
          row.statusDetail = event.detail;
        case 'deliveryFailed':
          row.status = SmsRowStatus.failed;
          row.error = event.detail ?? 'The carrier reported failed delivery.';
        default:
          row.statusDetail = event.detail ?? 'Unknown status: ${event.status}';
      }
    });
  }

  Future<void> _pickCsv() async {
    try {
      final file = await _smsService.pickCsv();
      if (file == null || !mounted) return;
      final parsed = _parser.parse(utf8.decode(file.bytes));
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
    } on PlatformException catch (error) {
      setState(() {
        _rows = [];
        _fileName = null;
        _error = error.message ?? 'Could not read the selected file.';
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
        row.messageId = null;
        row.statusDetail = null;
      }
    });

    final runId = DateTime.now().microsecondsSinceEpoch;
    for (var index = 0; index < _rows.length; index++) {
      if (_cancelRequested) break;
      final row = _rows[index];
      final messageId = '$runId-$index';
      setState(() {
        row.messageId = messageId;
        row.status = SmsRowStatus.submitting;
        row.statusDetail = 'Waiting for carrier submission callback';
      });
      try {
        final submission = await _smsService.send(
          phoneNumber: row.phoneNumber,
          message: row.message,
          messageId: messageId,
        );
        if (!mounted) return;
        setState(() {
          if (row.status == SmsRowStatus.submitting) {
            row.status = SmsRowStatus.carrierAccepted;
            row.statusDetail =
                'Carrier accepted ${submission.parts} SMS '
                '${submission.parts == 1 ? 'part' : 'parts'}; '
                'awaiting delivery report';
          }
        });
      } on PlatformException catch (error) {
        if (!mounted) return;
        setState(() {
          row.status = SmsRowStatus.failed;
          row.error = error.message ?? error.code;
          row.statusDetail = null;
        });
      }

      if (index < _rows.length - 1 && !_cancelRequested && delaySeconds > 0) {
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
    final accepted = _rows
        .where(
          (row) =>
              row.status == SmsRowStatus.carrierAccepted ||
              row.status == SmsRowStatus.deliveryUnconfirmed,
        )
        .length;
    final delivered = _rows
        .where((row) => row.status == SmsRowStatus.delivered)
        .length;
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
                    Text(
                      'Carrier accepted $accepted · Delivered $delivered · '
                      'Failed $failed · Total ${_rows.length}',
                    ),
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
                            [
                              row.message,
                              _statusLabel(row),
                              if (row.error != null) row.error!,
                            ].join('\n'),
                          ),
                          isThreeLine: true,
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

String _statusLabel(SmsRow row) {
  final state = switch (row.status) {
    SmsRowStatus.pending => 'Pending',
    SmsRowStatus.submitting => 'Submitting to carrier…',
    SmsRowStatus.carrierAccepted => 'Carrier accepted',
    SmsRowStatus.deliveryUnconfirmed => 'Delivery unconfirmed',
    SmsRowStatus.delivered => 'Delivered',
    SmsRowStatus.failed => 'Failed',
  };
  return row.statusDetail == null ? state : '$state — ${row.statusDetail}';
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final SmsRowStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      SmsRowStatus.pending => const Icon(Icons.schedule),
      SmsRowStatus.submitting => const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      SmsRowStatus.carrierAccepted => const Icon(
        Icons.outbox,
        color: Colors.blue,
      ),
      SmsRowStatus.deliveryUnconfirmed => const Icon(
        Icons.help,
        color: Colors.orange,
      ),
      SmsRowStatus.delivered => const Icon(
        Icons.check_circle,
        color: Colors.green,
      ),
      SmsRowStatus.failed => Icon(
        Icons.error,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}
