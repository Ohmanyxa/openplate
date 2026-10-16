# OpenPlate for Home Assistant

This custom integration receives confirmed observations from the OpenPlate iPhone app. It does not run
the ML models and does not expose a garage-door action.

## Installation

Install `https://github.com/Ohmanyxa/openplate` as a HACS custom repository of category
**Integration**. Alternatively copy the repository's `custom_components/openplate` directory into
Home Assistant's `/config/custom_components/`. Restart Home Assistant, then add **OpenPlate** under
**Settings → Devices & services**.

Initial setup displays the QR immediately if Home Assistant has a configured HTTPS URL. Otherwise,
enter only the Home Assistant HTTPS base URL reachable from the iPhone. Device identity and keys are
generated automatically. In the iPhone app, tap the pairing button and scan the code, then confirm
the QR screen in Home Assistant. No recognition server settings or registered plates are needed to pair.

After pairing, select **Configure → Configure recognition server** to enter the running recognition
server HTTPS URL, its API key and the capture interval. The integration does not start this server itself.
The open app retrieves settings automatically within about 15 seconds using signed HTTPS requests;
another QR scan is unnecessary. Until then, it shows that it is paired but waiting for recognition setup.
Configure registered plates separately, one per line as `BAB123=Family car`. Adjust the not-seen timeout
under advanced settings.

The QR contains a random 256-bit one-time token, the HTTPS pairing endpoint and an expiry time.
It contains no permanent credentials. Home Assistant consumes the token on its first successful
exchange and sends the configuration with cache prevention headers. Treat the QR as sensitive while
it is valid. The iPhone stores the recognition API key and signing key in iOS Keychain. Home Assistant
stores configuration in its normal configuration-entry storage; protect the host and its backups.
Both HTTPS certificates must be trusted by the iPhone, including when using a local certificate authority.

To change settings later, open **Settings → Devices & services → OpenPlate → Configure**. The menu
contains dedicated screens for registered plates, recognition, iPhone pairing and the not-seen timeout. Starting a
new pairing generates a new signing key; scan the code before confirming it because the previous app
key stops working after confirmation.

The integration creates:

- a last-plate sensor with confidence and registration metadata;
- one `recently seen` binary sensor per configured plate;
- an event entity emitting `recognized`, `appeared` and `disappeared`.

`disappeared` means the plate was no longer observed before the configured timeout. It does **not**
prove that a vehicle left the garage. Do not close a door based on that event alone.

## Automation boundary

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

The app sends JSON through HTTPS and signs the exact request with HMAC-SHA256. Home Assistant rejects
old timestamps, modified bodies and reused nonces. TLS must terminate at Home Assistant or a trusted
local reverse proxy; plain HTTP is intentionally rejected by the app configuration.

## Pairing regression tests

These tests exercise the one-time gateway and form selectors against Home Assistant 2026.10.1:

```bash
PYTHONPATH=. uv run --no-project --python 3.14 --with 'homeassistant==2026.10.1' \
  python -m unittest discover -s integrations/home_assistant/tests -v
```
