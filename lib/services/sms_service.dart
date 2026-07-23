import 'package:flutter/services.dart';

class SmsService {
  const SmsService();

  static const _channel = MethodChannel('sms_bulk_sender/sms');

  Future<bool> requestPermission() async {
    return await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
  }

  Future<void> send({
    required String phoneNumber,
    required String message,
  }) {
    return _channel.invokeMethod<void>('sendSms', {
      'phoneNumber': phoneNumber,
      'message': message,
    });
  }
}
