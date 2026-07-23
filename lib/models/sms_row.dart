enum SmsRowStatus { pending, sending, sent, failed }

class SmsRow {
  SmsRow({
    required this.phoneNumber,
    required this.message,
    this.status = SmsRowStatus.pending,
    this.error,
  });

  final String phoneNumber;
  final String message;
  SmsRowStatus status;
  String? error;

  SmsRow copy() => SmsRow(
    phoneNumber: phoneNumber,
    message: message,
    status: status,
    error: error,
  );
}
