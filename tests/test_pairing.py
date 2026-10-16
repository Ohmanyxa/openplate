import importlib.util
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

MODULE_PATH = Path(__file__).parents[1] / "custom_components/openplate/pairing.py"
SPEC = importlib.util.spec_from_file_location("openplate_ha_pairing", MODULE_PATH)
assert SPEC and SPEC.loader
pairing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pairing)


def test_pairing_uri_contains_https_webhook_and_expiry() -> None:
    uri = pairing.build_pairing_uri(
        home_assistant_url="https://ha.example.test/",
        webhook_id="webhook-id",
        device_id="iphone_gate",
        secret="x" * 32,
        issued_at=datetime.fromtimestamp(1_700_000_000, timezone.utc),
        lifetime_seconds=600,
    )

    parsed = urlsplit(uri)
    values = parse_qs(parsed.query)
    assert (parsed.scheme, parsed.netloc) == ("openplate", "pair")
    assert values["version"] == ["1"]
    assert values["device_id"] == ["iphone_gate"]
    assert values["home_assistant_webhook_url"] == [
        "https://ha.example.test/api/webhook/webhook-id"
    ]
    assert values["webhook_secret"] == ["x" * 32]
    assert values["expires_at"] == ["1700000600"]


def test_pairing_rejects_insecure_or_ambiguous_base_urls() -> None:
    for value in (
        "http://ha.local",
        "https://ha.local?token=unexpected",
        "ha.local",
    ):
        try:
            pairing.normalize_https_base_url(value)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Expected {value!r} to be rejected")
