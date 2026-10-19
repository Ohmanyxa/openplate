# OpenPlate for Home Assistant

This custom integration receives confirmed observations from the OpenPlate iPhone app. It does not run
the ML models and does not expose a garage-door action.

## Installation

Install `https://github.com/Ohmanyxa/openplate` as a HACS custom repository of category
**Integration**. Alternatively copy the repository's `custom_components/openplate` directory into
Home Assistant's `/config/custom_components/`. Restart Home Assistant, then add **OpenPlate** under
**Settings → Devices & services**.

Initial setup detects the local HA URL, including `http://homeassistant.local:8123` or a private IP,
and displays the QR immediately. If detection fails, confirm or correct the suggested local address.
No HTTPS setup or certificates are needed for this Home Assistant connection. Device identity and keys are
generated automatically. In the iPhone app, tap the pairing button and scan the code, then confirm
the QR screen in Home Assistant. No recognition server settings or registered plates are needed to pair.

Detection, OCR and temporal confirmation run locally on the iPhone. HA runs no model; a Pi 5 only
handles small encrypted observation messages and plate matching. The first recognition start downloads
hash-pinned models on the phone; subsequent recognition is offline. Under **Configure → On-device
recognition**, start with a 1-second processing interval. The open app retrieves settings within about
15 seconds using encrypted requests; another QR scan is unnecessary. Legacy server settings are ignored.
Configure registered plates separately, one per line as `BAB123=Family car`. Adjust the not-seen timeout
under advanced settings.

The QR contains an offer ID, a temporary random 256-bit encryption key, the pairing endpoint and expiry.
It contains no permanent credentials. The temporary key is never sent over the network. Home Assistant
consumes the offer on its first successfully authenticated exchange; invalid requests do not consume it.
Treat the QR as sensitive while valid. The iPhone stores the device key in iOS Keychain. Home Assistant
stores configuration in its normal configuration-entry storage; protect the host and its backups.
Camera frames are never sent to HA or a recognition server.

To change settings later, open **Settings → Devices & services → OpenPlate → Configure**. The menu
has three entries: Manage plates, Pair an iPhone, and Camera and connection.
Each plate is edited in its own form with separate plate and display-name fields. No spaces,
hyphens or PLATE=Name syntax are needed. Camera and connection contains recognition, HA URL and timeout. Starting a
new pairing generates a new signing key; scan the code before confirming it because the previous app
key stops working after confirmation.

The integration creates:

- a last-plate sensor with confidence and registration metadata;
- one detected binary sensor per configured plate (`on` / `off`, internally true / false);
- one direction enum sensor per plate: `arrival`, `departure`, `stationary`, `unknown`;
- an event entity emitting `recognized`, `appeared`, `disappeared`, `arrival`, `departure`.

`disappeared` means the plate was no longer observed before the configured timeout. It does **not**
prove that a vehicle left the garage. Do not close a door based on that event alone.

## Automation boundary

### Per-plate presence and direction

Plate size growing consistently means `arrival` (towards the camera); shrinking means
`departure` (away from the camera). At least four frames over two seconds are required.
Changing position alone does not imply arrival/departure. Stationary or uncertain estimates have
their own states. Presence returns to off after the configured not-seen timeout, and direction to
unknown. Direction describes the most recent processed observation, not a continuously verified state.

The integration calls **no cover/switch services**, even if old saved garage options are enabled.
Garage/action menus and garage movement sensors have been retired. Existing registered plates,
pairings and presence unique IDs are retained. Deleted plate entities are removed from the registry.
Old garage settings remain stored but are ignored; move any desired actions into HA automations.

Missing motion from older apps is unknown. Presence may turn on before the fourth frame needed for
direction: trigger on the direction sensor transition, not only presence off → on.
Camera-relative direction is not necessarily arrival at a property if the camera faces the other way.
Umlauts remain exact identities: `MÜ` and `MU` are never aliases. The new iPhone build uses a
local Vision crop recheck because the CCT alphabet has no umlaut classes. Vision must read the
umlaut and agree on every other character; registration never substitutes it. Accuracy still depends
on actual images. See [setup and automation guidance](../../docs/GARAGES.md) and the
[security review](../../docs/SECURITY_REVIEW_2026-10-19.md).

A conservative opening automation can use a registered plate sensor only as one condition among
several. Entity IDs must be adapted to the names created in your instance:

```yaml
alias: Open garage for recognized family car
triggers:
  - trigger: state
    entity_id: sensor.mueab123_direction
    to: "arrival"
conditions:
  - condition: state
    entity_id: person.owner
    state: home
  - condition: state
    entity_id: cover.garage_door
    state: closed
actions:
  - action: cover.open_cover
    target:
      entity_id: cover.garage_door
mode: single
```

For automatic closing, add an independent safety/occupancy sensor and the door controller's obstruction
protection. Directional line crossing is planned but not present in this increment.

## Transport

The app and integration encrypt and authenticate JSON with AES-256-GCM and direction-specific keys
derived by HKDF-SHA256. Replies are bound to the request and HTTP status. Modified data, stale messages,
replays and plaintext success replies are rejected. A fresh session on each HA entry setup prevents
recorded plate requests from being replayed after reload/restart; the app refreshes sessions automatically.
Public HTTP hosts are rejected; use local names, private IPs or HTTPS. The iOS app enables local-network
access without globally disabling transport security. See [the wire specification](../../docs/ENCRYPTED_TRANSPORT.md).

Update both components to v0.5.0 or later and pair again to rotate the key and disable legacy plaintext
HMAC requests. Existing HTTPS entries temporarily retain the legacy path for old clients; local HTTP
never accepts it. The HA browser interface itself is outside the encrypted OpenPlate channel: display
the QR from a trusted HA interface. The protocol has not received an independent security audit.

Possession of the paired key authenticates observations, not their camera provenance. A compromised
phone/key or a copied physical plate remains outside that guarantee. A plate match alone must not
authorize a garage door.

## Pairing regression tests

These tests exercise the one-time gateway and form selectors against Home Assistant 2026.10.1:

```bash
PYTHONPATH=. uv run --no-project --python 3.14 --with 'homeassistant==2026.10.1' \
  python -m unittest discover -s integrations/home_assistant/tests -v
```

For a real Dart/Python HTTP round trip, run the localhost-only test harness in one terminal:

```bash
PYTHONPATH=. uv run --no-project --python 3.14 --with 'homeassistant==2026.10.1' \
  python integrations/home_assistant/tests/interop_server.py
```

Use its printed URL in another terminal, from `apps/openplate_mobile`:

```bash
OPENPLATE_INTEROP_URL=http://127.0.0.1:PORT flutter test test/http_interop_test.dart
```

The harness exposes test-only bootstrap/state routes on loopback and is not part of the installed integration.
