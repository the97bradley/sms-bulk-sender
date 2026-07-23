import 'package:csv/csv.dart';

import '../models/sms_row.dart';

class SmsCsvParser {
  const SmsCsvParser();

  List<SmsRow> parse(String source) {
    final input = source.startsWith('\uFEFF') ? source.substring(1) : source;
    final rows = csv.decode(input);
    if (rows.isEmpty) {
      throw const FormatException('The CSV is empty.');
    }

    final header = rows.first.map((cell) => _normalizeHeader('$cell')).toList();
    if (header.length != 2 ||
        header[0] != 'phone number' ||
        header[1] != 'message') {
      throw const FormatException(
        'The header must contain exactly: phone number,message',
      );
    }

    final messages = <SmsRow>[];
    for (var index = 1; index < rows.length; index++) {
      final rowNumber = index + 1;
      final row = rows[index];
      if (row.length != 2) {
        throw FormatException(
          'Row $rowNumber must contain exactly 2 columns.',
        );
      }

      final rawPhone = '${row[0]}'.trim();
      final message = '${row[1]}'.trim();
      if (rawPhone.isEmpty && message.isEmpty) {
        continue;
      }
      final phone = _normalizePhone(rawPhone, rowNumber);
      if (message.isEmpty) {
        throw FormatException('Row $rowNumber has an empty message.');
      }
      messages.add(SmsRow(phoneNumber: phone, message: message));
    }

    if (messages.isEmpty) {
      throw const FormatException('The CSV contains no message rows.');
    }
    return messages;
  }

  String _normalizeHeader(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ');

  String _normalizePhone(String value, int rowNumber) {
    if (!RegExp(r'^\+?[0-9().\s-]+$').hasMatch(value)) {
      throw FormatException('Row $rowNumber has an invalid phone number.');
    }
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7 || digits.length > 15) {
      throw FormatException(
        'Row $rowNumber phone number must contain 7–15 digits.',
      );
    }
    return value.startsWith('+') ? '+$digits' : digits;
  }
}
