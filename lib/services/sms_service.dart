import 'package:flutter/services.dart';

class PickedCsv {
  const PickedCsv({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class SmsService {
  const SmsService();

  static const _channel = MethodChannel('sms_bulk_sender/sms');

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

  Future<void> send({required String phoneNumber, required String message}) {
    return _channel.invokeMethod<void>('sendSms', {
      'phoneNumber': phoneNumber,
      'message': message,
    });
  }
}
