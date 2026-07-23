"""Load and validate confirmed-artist SMS recipients."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping

import gspread
from google.oauth2.service_account import Credentials

DEFAULT_SPREADSHEET_ID = "1ttZCF7dE0KAeQKyMeaSCx3KwtC0R4iXr4A_i528HOyE"
DEFAULT_WORKSHEET = "Form Responses 1"
AVAILABILITY_COLUMN = "I am available to play Denver PorchFest on October 3rd"
PHONE_COLUMN = "Contact phone"
ARTIST_NAME_COLUMN = "Artist Name - EXACTLY how you want it on the poster"
CONTACT_NAME_COLUMN = "Contact name"
SHEETS_READONLY_SCOPE = "https://www.googleapis.com/auth/spreadsheets.readonly"


@dataclass(frozen=True)
class Recipient:
    name: str
    phone: str
    sheet_row: int


@dataclass(frozen=True)
class RecipientLoad:
    recipients: list[Recipient]
    unavailable: int
    invalid_phones: list[tuple[int, str]]
    duplicate_phones: int


def normalize_us_phone(value: str) -> str | None:
    """Normalize a US phone number to E.164, or return None when invalid."""
    before_extension = re.split(r"(?:ext\.?|x)\s*\d+\s*$", value, flags=re.I)[0]
    digits = re.sub(r"\D", "", before_extension)
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    return None


def rows_to_recipients(rows: Iterable[Mapping[str, Any]]) -> RecipientLoad:
    recipients: list[Recipient] = []
    invalid_phones: list[tuple[int, str]] = []
    unavailable = 0
    duplicate_phones = 0
    seen: set[str] = set()

    for sheet_row, row in enumerate(rows, start=2):
        availability = str(row.get(AVAILABILITY_COLUMN, "") or "").strip().lower()
        if not availability.startswith("yes"):
            unavailable += 1
            continue

        raw_phone = str(row.get(PHONE_COLUMN, "") or "").strip()
        phone = normalize_us_phone(raw_phone)
        if phone is None:
            invalid_phones.append((sheet_row, raw_phone))
            continue
        if phone in seen:
            duplicate_phones += 1
            continue

        name = str(
            row.get(ARTIST_NAME_COLUMN)
            or row.get(CONTACT_NAME_COLUMN)
            or f"Sheet row {sheet_row}"
        ).strip()
        recipients.append(Recipient(name=name, phone=phone, sheet_row=sheet_row))
        seen.add(phone)

    return RecipientLoad(
        recipients=recipients,
        unavailable=unavailable,
        invalid_phones=invalid_phones,
        duplicate_phones=duplicate_phones,
    )


def _service_account_info() -> dict[str, Any]:
    raw = os.environ.get("GOOGLE_SERVICE_ACCOUNT_JSON")
    if not raw:
        raise RuntimeError("GOOGLE_SERVICE_ACCOUNT_JSON is not set")
    try:
        info = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"GOOGLE_SERVICE_ACCOUNT_JSON is not valid JSON: {exc}"
        ) from exc
    if not info.get("client_email") or not info.get("private_key"):
        raise RuntimeError(
            "GOOGLE_SERVICE_ACCOUNT_JSON must include client_email and private_key"
        )
    return info


def load_confirmed_recipients(
    spreadsheet_id: str | None = None,
    worksheet_name: str | None = None,
) -> RecipientLoad:
    """Read confirmed artists from Google Sheets without modifying the sheet."""
    credentials = Credentials.from_service_account_info(
        _service_account_info(), scopes=[SHEETS_READONLY_SCOPE]
    )
    client = gspread.authorize(credentials)
    worksheet = client.open_by_key(
        spreadsheet_id
        or os.environ.get("CONFIRMATION_SPREADSHEET_ID")
        or DEFAULT_SPREADSHEET_ID
    ).worksheet(
        worksheet_name
        or os.environ.get("CONFIRMATION_WORKSHEET")
        or DEFAULT_WORKSHEET
    )
    rows = worksheet.get_all_records(default_blank="")
    return rows_to_recipients(rows)
