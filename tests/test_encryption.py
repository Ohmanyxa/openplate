"""Shared Python/Dart vectors and authenticated-envelope rejection tests."""

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location(
    "openplate_encryption", ROOT / "custom_components/openplate/encryption.py"
)
assert SPEC and SPEC.loader
encryption = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(encryption)
VECTOR = json.loads((ROOT / "tests/fixtures/encrypted_transport_v2.json").read_text())


def test_shared_vector_encrypts_and_decrypts_identically():
    assert (
        encryption.seal(
            VECTOR["payload"],
            VECTOR["secret"],
            VECTOR["context"],
            message_id=VECTOR["envelope"]["id"],
            now=VECTOR["envelope"]["timestamp"],
            nonce=bytes(range(12)),
        )
        == VECTOR["envelope"]
    )
    assert (
        encryption.unseal(
            VECTOR["envelope"],
            VECTOR["secret"],
            VECTOR["context"],
            now=VECTOR["envelope"]["timestamp"],
        )
        == VECTOR["payload"]
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("id", "changed0123456789"),
        ("timestamp", 1700000001),
        ("nonce", "AAAAAAAAAAAAAAAA"),
        ("ciphertext", "AAAAAAAAAAAAAAAAAAAAAA"),
        ("version", 1),
        ("timestamp", True),
        ("nonce", []),
    ],
)
def test_metadata_and_ciphertext_manipulation_is_rejected(field, value):
    envelope = {**VECTOR["envelope"], field: value}
    with pytest.raises(ValueError):
        encryption.unseal(envelope, VECTOR["secret"], VECTOR["context"], now=1700000000)


def test_wrong_key_direction_and_expired_envelope_are_rejected():
    for secret, context, now in [
        ("w" * 43, VECTOR["context"], 1700000000),
        (VECTOR["secret"], "device/response/other", 1700000000),
        (VECTOR["secret"], VECTOR["context"], 1700000091),
    ]:
        with pytest.raises(ValueError):
            encryption.unseal(VECTOR["envelope"], secret, context, now=now)
