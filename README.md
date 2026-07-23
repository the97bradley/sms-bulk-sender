# SMS Bulk Sender

Android Flutter app that imports a personalized SMS queue from CSV and sends
each row from the phone's SIM with a configurable delay.

This app does not use InfiniReach, Twilio, or another SMS API.

## CSV format

The CSV must be UTF-8 and contain exactly two columns in this order:

```csv
phone number,message
+13035551212,"Your custom message, including commas if needed."
7205551212,Another recipient gets a different message.
```

The importer:

- requires the `phone number,message` header;
- supports quoted commas and multiline messages;
- rejects blank messages and malformed phone numbers;
- preserves every valid row, including repeated phone numbers;
- shows the complete queue for review before sending.

## Use

1. Install the app on an Android phone with an active SIM.
2. Tap **Import CSV** and choose the file.
3. Set the delay in seconds.
4. Review every phone number and message.
5. Tap **Send**, confirm the count, and grant Android's SMS permission.
6. Leave the app open until the queue finishes. Tap **Stop** to stop before the
   next row.

Long messages are sent as multipart SMS. A green check means Android accepted
the send request; it is not a carrier delivery receipt.

## Development

Requires Flutter with Dart 3.12 or newer:

```bash
flutter pub get
flutter test
flutter analyze
flutter run
```

Only Android is included because iOS does not permit apps to silently iterate
and send SMS messages. Direct `SEND_SMS` permission is also restricted for apps
distributed through Google Play; this tool is intended for controlled,
sideloaded operational use.
