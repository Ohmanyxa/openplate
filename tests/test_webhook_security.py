import importlib.util
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "custom_components/openplate/security.py"
SPEC = importlib.util.spec_from_file_location("openplate_ha_security", MODULE_PATH)
assert SPEC and SPEC.loader
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)


def test_signature_and_timestamp_are_verified() -> None:
    body = b'{"plate":"BTEST1"}'
    signature = security.signature_for("x" * 32, "1000", "event-1", body)
    assert security.valid_signature("x" * 32, "1000", "event-1", body, signature, now=1005)
    assert not security.valid_signature(
        "x" * 32, "1000", "event-1", body + b" ", signature, now=1005
    )
    assert not security.valid_signature("x" * 32, "1000", "event-1", body, signature, now=1200)
