from sms_bulk_sender.recipients import (
    ARTIST_NAME_COLUMN,
    AVAILABILITY_COLUMN,
    PHONE_COLUMN,
    normalize_us_phone,
    rows_to_recipients,
)


def test_normalize_us_phone() -> None:
    assert normalize_us_phone("(303) 555-1212") == "+13035551212"
    assert normalize_us_phone("+1 303 555 1212") == "+13035551212"
    assert normalize_us_phone("303-555-1212 ext. 9") == "+13035551212"
    assert normalize_us_phone("555-1212") is None
    assert normalize_us_phone("+44 20 7946 0958") is None


def test_rows_to_recipients_filters_and_deduplicates() -> None:
    rows = [
        {
            AVAILABILITY_COLUMN: "Yes, I am available",
            ARTIST_NAME_COLUMN: "First Band",
            PHONE_COLUMN: "(303) 555-1212",
        },
        {
            AVAILABILITY_COLUMN: "No",
            ARTIST_NAME_COLUMN: "Unavailable Band",
            PHONE_COLUMN: "3035552222",
        },
        {
            AVAILABILITY_COLUMN: "YES",
            ARTIST_NAME_COLUMN: "Duplicate Contact",
            PHONE_COLUMN: "+1 303 555 1212",
        },
        {
            AVAILABILITY_COLUMN: "Yes",
            ARTIST_NAME_COLUMN: "Bad Number",
            PHONE_COLUMN: "123",
        },
    ]

    loaded = rows_to_recipients(rows)

    assert [(r.name, r.phone, r.sheet_row) for r in loaded.recipients] == [
        ("First Band", "+13035551212", 2)
    ]
    assert loaded.unavailable == 1
    assert loaded.duplicate_phones == 1
    assert loaded.invalid_phones == [(5, "123")]
