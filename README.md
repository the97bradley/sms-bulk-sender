# Denver PorchFest SMS Bulk Sender

Standalone command-line tool for sending carefully reviewed SMS blasts through
InfiniReach. Its current recipient source is the Denver PorchFest artist
confirmation Google Sheet.

The tool is safe by default:

- It reads Google Sheets with a read-only OAuth scope.
- It includes only rows whose availability answer starts with `Yes`.
- It validates and deduplicates US phone numbers.
- It performs a dry run unless `--send` is supplied.
- Live sends require `--confirm-count` to match the final recipient count.
- It verifies that the configured Android sender is online and SMS-ready.
- It writes a local, gitignored JSONL result log.

## Setup

Python 3.11 or newer is required.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
```

Set these secrets in your shell or runtime secret manager:

```bash
export GOOGLE_SERVICE_ACCOUNT_JSON='{"type":"service_account", ...}'
export SMS_GATEWAY_KEY='...'
```

See `.env.example` for non-secret defaults. The Google service account needs
viewer access to the confirmation spreadsheet.

## Verify the sender

```bash
porchfest-sms --check-device
```

The current InfiniReach relay is an Android device using
`+15024685991`. InfiniReach rejects generic script user agents, so the client
intentionally sends a browser user agent.

## Preview a blast

Dry run is the default and does not send anything:

```bash
porchfest-sms --message-file message.txt
```

Review the message, recipient count, invalid numbers, duplicates, and every
selected artist before proceeding. `--limit N` can restrict the final list for
a controlled test.

## Send

Use the exact count printed by the dry run:

```bash
porchfest-sms \
  --message-file message.txt \
  --campaign-id confirmed-artists-2026-07-23 \
  --send \
  --confirm-count 96
```

Choose a unique, stable `--campaign-id` for each blast. It becomes part of each
message's external idempotency key. By default, sends are spaced 0.65 seconds
apart to stay below the approximate 100-message/minute gateway limit.

Do not send an artist blast until the message copy and live-send approval are
explicitly provided.

## Tests

```bash
python -m pip install pytest
pytest
```

The tests mock network calls and never send SMS messages.
