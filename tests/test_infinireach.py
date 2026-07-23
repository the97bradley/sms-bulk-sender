import io
import json
from unittest.mock import patch

from sms_bulk_sender.infinireach import InfiniReachClient


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.body = io.BytesIO(json.dumps(payload).encode())

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body.read()


def test_device_ready_for_configured_sender() -> None:
    response = FakeResponse(
        {
            "devices": [
                {
                    "id": "device-1",
                    "name": "Android",
                    "status": "online",
                    "simSlots": [
                        {
                            "phoneNumber": "5024685991",
                            "smsReady": True,
                        }
                    ],
                }
            ]
        }
    )
    client = InfiniReachClient(api_key="test-key", from_number="+15024685991")

    with patch("urllib.request.urlopen", return_value=response):
        device = client.assert_sender_ready()

    assert device.device_id == "device-1"
    assert device.phone_number == "+15024685991"


def test_send_message_payload() -> None:
    response = FakeResponse({"id": "message-1", "status": "queued"})
    client = InfiniReachClient(api_key="test-key")

    with patch("urllib.request.urlopen", return_value=response) as urlopen:
        result = client.send_message(
            to="+13035551212",
            message="Hello",
            external_id="campaign-recipient",
        )

    request = urlopen.call_args.args[0]
    assert json.loads(request.data) == {
        "to": "+13035551212",
        "message": "Hello",
        "from": "+15024685991",
        "channel": "sms",
        "externalId": "campaign-recipient",
    }
    assert result["status"] == "queued"
