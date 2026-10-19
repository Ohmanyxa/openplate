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
contains dedicated screens for registered plates, recognition, HA address, iPhone pairing and timeout. Starting a
new pairing generates a new signing key; scan the code before confirming it because the previous app
key stops working after confirmation.

The integration creates:

- a last-plate sensor with confidence and registration metadata;
- one `recently seen` binary sensor per configured plate;
- an event entity emitting `recognized`, `appeared` and `disappeared`.

`disappeared` means the plate was no longer observed before the configured timeout. It does **not**
prove that a vehicle left the garage. Do not close a door based on that event alone.

## Automation boundary

### Per-plate garage assignment and motion (development worktree)

Under **Configure → Assign plates to garage doors**, select a registered plate, then an existing
`cover.*` entity. Choose “Remove current assignment” to clear it. A cover selector permits custom
garage integrations that do not declare a garage device class; select the intended garage door.
This is an association only: the integration calls no door services and creates no automation.

`garage_entity_id` is attached to recognition/appearance/disappearance events and the per-plate
presence sensor. Assignment is server-owned; observations cannot supply/override the target cover.
New clients optionally send validated `motion` metadata: `direction` (`approaching`, `receding`,
`stationary`, `unknown`), normalized image-plane `dx`/`dy`, relative `scale_rate`, sample count and
time span. Each presence sensor exposes `direction` and `motion`, resetting to unknown on absence.
These are fixed-camera optical estimates, not a calibrated 3D velocity or safety sensor. Missing
motion from an older app is unknown. Do not interpret unknown as departure or act on timeout alone.
Direction is the last observed estimate, not a continuously verified current state. Initial plate
confirmation may precede the fourth frame needed for motion: an `off → on` presence trigger with an
approach condition can therefore miss it. For logging/testing, watch later `recognized` events or
the `direction` attribute transition; do not turn this into a door action without additional safeguards.

Umlauts are now preserved in registered identities: `MÜ`, `MU` and `M` are distinct. Existing ASCII
IDs are unchanged; review old umlaut entity IDs/automations after upgrading. The deployed model still
has no umlaut output classes. Registering `MÜ` does not make an OCR result `MU` authorized.
See the [security review](../../docs/SECURITY_REVIEW_2026-10-19.md) before automatic door control.

A conservative opening automation can use a registered plate sensor only as one condition among
several. Entity IDs must be adapted to the names created in your instance:

```yaml
alias: Open garage for recognized family car
triggers:
  - trigger: state
    entity_id: binary_sensor.family_car_recently_seen
    from: "off"
    to: "on"
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

## Garages with built-in actions

Configure → **Garages and direct control** creates named garages with multiple
registered plates, an existing cover/switch, camera orientation and separate
`arrival` / `departure` actions. Direct control is off by default and requires
explicit opt-in. Each garage gets a movement sensor; no user automation is needed.
See [setup, action limits and safety requirements](../../docs/GARAGES.md).
Do not use plate matching as secure vehicle authentication or direction as proof
that the doorway is clear. Independent door safety sensors remain essential.

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
