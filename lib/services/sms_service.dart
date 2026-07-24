import 'package:flutter/services.dart';

class PickedCsv {
  const PickedCsv({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class SmsSubmission {
  const SmsSubmission({required this.messageId, required this.parts});

  final String messageId;
  final int parts;
}

class SmsStatusEvent {
  const SmsStatusEvent({
    required this.messageId,
    required this.status,
    this.detail,
  });

  final String messageId;
  final String status;
  final String? detail;
}

class SmsService {
  const SmsService();

  static const _channel = MethodChannel('sms_bulk_sender/sms');
  static const _statusChannel = EventChannel('sms_bulk_sender/sms_status');

  Stream<SmsStatusEvent> get statusEvents =>
      _statusChannel.receiveBroadcastStream().map((event) {
        final data = Map<Object?, Object?>.from(event as Map);
        return SmsStatusEvent(
          messageId: data['messageId']! as String,
          status: data['status']! as String,
          detail: data['detail'] as String?,
        );
      });

  Future<PickedCsv?> pickCsv() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickCsv',
    );
    if (result == null) return null;
    return PickedCsv(
      name: result['name']! as String,
      bytes: result['bytes']! as Uint8List,
    );
  }

  Future<bool> requestPermission() async {
    return await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
  }

  Future<SmsSubmission> send({
    required String phoneNumber,
    required String message,
    required String messageId,
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'sendSms',
      {'phoneNumber': phoneNumber, 'message': message, 'messageId': messageId},
    );
    if (result == null) {
      throw const PlatformException(
        code: 'invalid_response',
        message: 'Android returned no send confirmation.',
      );
    }
    return SmsSubmission(
      messageId: result['messageId']! as String,
      parts: result['parts']! as int,
    );
  }
}
