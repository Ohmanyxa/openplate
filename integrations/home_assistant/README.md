# OpenPlate for Home Assistant

This custom integration receives confirmed observations from the OpenPlate iPhone app. It does not run
the ML models and does not expose a garage-door action.

## Installation

Install `https://github.com/Ohmanyxa/openplate` as a HACS custom repository of category
**Integration**. Alternatively copy the repository's `custom_components/openplate` directory into
Home Assistant's `/config/custom_components/`. Restart Home Assistant, then add **OpenPlate** under
**Settings → Devices & services**.

During initial setup, configure:

- Device ID: a stable name for the mounted iPhone.
- Home Assistant HTTPS URL: the base URL reachable from the iPhone.
- Registered plates: one per line, for example `BAB123=Family car`.
- Not-seen timeout: when the per-plate binary sensor returns to off.

OpenPlate then displays a ten-minute QR pairing code. In the iPhone app, open **Connection**, select
**Scan Home Assistant QR code**, scan the code and save the remaining recognition-server settings.
The QR code transfers the device ID, complete webhook URL and a generated HMAC signing key. It never
leaves the local Home Assistant browser-to-iPhone camera path.

To change settings later, open **Settings → Devices & services → OpenPlate → Configure**. The menu
contains dedicated screens for registered plates, iPhone pairing and the not-seen timeout. Starting a
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
