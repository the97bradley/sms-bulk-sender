import 'package:flutter_test/flutter_test.dart';
import 'package:sms_bulk_sender/services/csv_parser.dart';

void main() {
  const parser = SmsCsvParser();

  test('parses personalized rows and normalizes phone punctuation', () {
    final rows = parser.parse('''
phone number,message
+1 (303) 555-1212,"Hello, Denver"
720-555-1212,Second message
''');

    expect(rows, hasLength(2));
    expect(rows[0].phoneNumber, '+13035551212');
    expect(rows[0].message, 'Hello, Denver');
    expect(rows[1].phoneNumber, '7205551212');
    expect(rows[1].message, 'Second message');
  });

  test('preserves duplicate phone numbers as separate rows', () {
    final rows = parser.parse('''
phone number,message
3035551212,First
3035551212,Second
''');

    expect(rows, hasLength(2));
    expect(rows.map((row) => row.message), ['First', 'Second']);
  });

  test('requires the two expected columns', () {
    expect(
      () => parser.parse('phone,message\n3035551212,Hello'),
      throwsFormatException,
    );
  });

  test('rejects invalid data with its row number', () {
    expect(
      () => parser.parse('phone number,message\nnot-a-number,Hello'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Row 2'),
        ),
      ),
    );
  });
}
