"""Command-line interface for safe PorchFest SMS blasts."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .infinireach import InfiniReachClient, InfiniReachError
from .recipients import Recipient, load_confirmed_recipients


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="porchfest-sms",
        description=(
            "Send an SMS blast to available artists on the confirmation sheet. "
            "The default mode is a dry run."
        ),
    )
    message = parser.add_mutually_exclusive_group()
    message.add_argument("--message", help="SMS message text")
    message.add_argument(
        "--message-file", type=Path, help="UTF-8 text file containing the message"
    )
    parser.add_argument(
        "--check-device",
        action="store_true",
        help="Check the configured InfiniReach sender and exit",
    )
    parser.add_argument(
        "--send",
        action="store_true",
        help="Actually send messages (otherwise only preview)",
    )
    parser.add_argument(
        "--confirm-count",
        type=int,
        help="Required with --send; must equal the final recipient count",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Use only the first N valid recipients (useful for controlled tests)",
    )
    parser.add_argument(
        "--campaign-id",
        help="Stable identifier used to construct idempotency keys",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.65,
        help="Seconds between sends (default: 0.65, below 100/minute)",
    )
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=Path("logs"),
        help="Local JSONL delivery-log directory (default: logs)",
    )
    return parser


def _message_from_args(args: argparse.Namespace, parser: argparse.ArgumentParser) -> str:
    if args.message_file:
        try:
            message = args.message_file.read_text(encoding="utf-8").strip()
        except OSError as exc:
            parser.error(f"could not read --message-file: {exc}")
    else:
        message = (args.message or "").strip()
    if not message:
        parser.error("--message or --message-file is required")
    if len(message) > 1600:
        parser.error(f"message is {len(message)} characters; maximum is 1600")
    return message


def _external_id(campaign_id: str, recipient: Recipient) -> str:
    digest = hashlib.sha256(recipient.phone.encode()).hexdigest()[:16]
    return f"{campaign_id}-{digest}"


def _write_log(path: Path, record: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)

    try:
        if args.check_device:
            client = InfiniReachClient()
            device = client.assert_sender_ready()
            print(
                f"Ready: {device.name} ({device.device_id}), "
                f"sender {device.phone_number}"
            )
            return 0

        message = _message_from_args(args, parser)
        loaded = load_confirmed_recipients()
    except (RuntimeError, ValueError, InfiniReachError) as exc:
        parser.exit(1, f"error: {exc}\n")

    recipients = loaded.recipients
    if args.limit is not None:
        if args.limit < 1:
            parser.error("--limit must be at least 1")
        recipients = recipients[: args.limit]

    print(f"Message ({len(message)} chars): {message}")
    print(
        f"Recipients: {len(recipients)} valid; "
        f"{loaded.unavailable} unavailable; "
        f"{len(loaded.invalid_phones)} invalid phone(s); "
        f"{loaded.duplicate_phones} duplicate phone(s)"
    )
    for recipient in recipients:
        print(f"  row {recipient.sheet_row}: {recipient.name} <{recipient.phone}>")
    for row_number, raw_phone in loaded.invalid_phones:
        print(
            f"  WARNING row {row_number}: invalid phone {raw_phone!r}",
            file=sys.stderr,
        )

    if not args.send:
        print("DRY RUN: nothing sent. Re-run with --send and --confirm-count.")
        return 0
    if args.confirm_count is None or args.confirm_count != len(recipients):
        parser.error(
            "--confirm-count must exactly match the final recipient count "
            f"({len(recipients)})"
        )

    try:
        client = InfiniReachClient()
        device = client.assert_sender_ready()
    except (InfiniReachError, ValueError) as exc:
        parser.exit(1, f"error: refusing to send: {exc}\n")
    print(f"Sender ready: {device.name} <{device.phone_number}>")

    campaign_id = args.campaign_id or datetime.now(UTC).strftime(
        "porchfest-%Y%m%dT%H%M%SZ"
    )
    log_path = args.log_dir / f"{campaign_id}-{uuid.uuid4().hex[:8]}.jsonl"
    failures = 0
    for index, recipient in enumerate(recipients, start=1):
        external_id = _external_id(campaign_id, recipient)
        timestamp = datetime.now(UTC).isoformat()
        try:
            response = client.send_message(
                to=recipient.phone,
                message=message,
                external_id=external_id,
            )
            status = "accepted"
            error = None
            print(f"[{index}/{len(recipients)}] accepted: {recipient.name}")
        except (InfiniReachError, ValueError) as exc:
            failures += 1
            response = None
            status = "failed"
            error = str(exc)
            print(
                f"[{index}/{len(recipients)}] FAILED: {recipient.name}: {exc}",
                file=sys.stderr,
            )
        _write_log(
            log_path,
            {
                "timestamp": timestamp,
                "campaign_id": campaign_id,
                "external_id": external_id,
                "sheet_row": recipient.sheet_row,
                "name": recipient.name,
                "phone": recipient.phone,
                "status": status,
                "error": error,
                "response": response,
            },
        )
        if index < len(recipients):
            time.sleep(args.delay)

    print(f"Complete: {len(recipients) - failures} accepted, {failures} failed")
    print(f"Delivery log: {log_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
