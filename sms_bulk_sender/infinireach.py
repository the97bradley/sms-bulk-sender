"""Small InfiniReach API client using only the Python standard library."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

DEFAULT_BASE_URL = "https://api.infinireach.io"
DEFAULT_FROM_NUMBER = "+15024685991"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0.0.0 Safari/537.36"
)


class InfiniReachError(RuntimeError):
    """An InfiniReach request failed."""


@dataclass(frozen=True)
class DeviceStatus:
    device_id: str
    name: str
    status: str
    sms_ready: bool
    phone_number: str


class InfiniReachClient:
    def __init__(
        self,
        api_key: str | None = None,
        *,
        base_url: str = DEFAULT_BASE_URL,
        from_number: str | None = None,
        timeout: float = 20,
    ) -> None:
        self.api_key = api_key or os.environ.get("SMS_GATEWAY_KEY", "")
        if not self.api_key:
            raise ValueError("SMS_GATEWAY_KEY is not set")
        self.base_url = base_url.rstrip("/")
        self.from_number = (
            from_number or os.environ.get("SMS_FROM_NUMBER") or DEFAULT_FROM_NUMBER
        )
        self.timeout = timeout

    def _request(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> Any:
        body = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            method=method,
            headers={
                "X-API-Key": self.api_key,
                "User-Agent": USER_AGENT,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                response_body = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise InfiniReachError(
                f"InfiniReach returned HTTP {exc.code}: {detail}"
            ) from exc
        except urllib.error.URLError as exc:
            raise InfiniReachError(f"Could not reach InfiniReach: {exc.reason}") from exc

        if not response_body:
            return {}
        try:
            return json.loads(response_body)
        except json.JSONDecodeError as exc:
            raise InfiniReachError("InfiniReach returned invalid JSON") from exc

    def list_devices(self) -> list[DeviceStatus]:
        response = self._request("GET", "/api/v1/devices")
        devices: list[DeviceStatus] = []
        for device in response.get("devices", []):
            for slot in device.get("simSlots", []):
                raw_phone = str(slot.get("phoneNumber", ""))
                phone = raw_phone if raw_phone.startswith("+") else f"+1{raw_phone}"
                devices.append(
                    DeviceStatus(
                        device_id=str(device.get("id", "")),
                        name=str(device.get("name", "")),
                        status=str(device.get("status", "")),
                        sms_ready=bool(slot.get("smsReady")),
                        phone_number=phone,
                    )
                )
        return devices

    def assert_sender_ready(self) -> DeviceStatus:
        for device in self.list_devices():
            if (
                device.phone_number == self.from_number
                and device.status == "online"
                and device.sms_ready
            ):
                return device
        raise InfiniReachError(
            f"No online, SMS-ready device found for {self.from_number}"
        )

    def send_message(
        self, *, to: str, message: str, external_id: str
    ) -> dict[str, Any]:
        if not message or len(message) > 1600:
            raise ValueError("message must contain 1 to 1600 characters")
        response = self._request(
            "POST",
            "/api/v1/messages",
            {
                "to": to,
                "message": message,
                "from": self.from_number,
                "channel": "sms",
                "externalId": external_id,
            },
        )
        if not isinstance(response, dict):
            raise InfiniReachError("InfiniReach returned an unexpected response")
        return response
