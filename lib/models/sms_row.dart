enum SmsRowStatus {
  pending,
  submitting,
  carrierAccepted,
  deliveryUnconfirmed,
  delivered,
  failed,
}

class SmsRow {
  SmsRow({
    required this.phoneNumber,
    required this.message,
    this.status = SmsRowStatus.pending,
    this.error,
    this.messageId,
    this.statusDetail,
  });

  final String phoneNumber;
  final String message;
  SmsRowStatus status;
  String? error;
  String? messageId;
  String? statusDetail;

  SmsRow copy() => SmsRow(
    phoneNumber: phoneNumber,
    message: message,
    status: status,
    error: error,
    messageId: messageId,
    statusDetail: statusDetail,
  );
}
