# OpenPlate encrypted transport v2

This application protocol uses the established AES-GCM and HKDF implementations in Python
[`cryptography`](https://cryptography.io/en/stable/hazmat/primitives/aead/) and Dart
[`cryptography`](https://pub.dev/documentation/cryptography/latest/cryptography/AesGcm-class.html).
It is not TLS, does not encrypt the HA browser interface, and has not had an independent security audit.
The separate recognition/frame API continues to require HTTPS.
Python uses the cryptography package already provided by Home Assistant core rather than replacing
HA's pinned dependency. Standalone Python tests declare it in the development dependencies.

## Cryptographic envelope

Both implementations use AES-256-GCM, a fresh CSPRNG-generated 12-byte nonce per encryption,
and the full 16-byte authentication tag. `ciphertext` is the ciphertext followed by the tag.
Binary fields are base64url without padding. JSON plaintext is UTF-8, compactly serialized.

```json
{"version":2,"id":"random-message-id","timestamp":1700000000,"nonce":"base64url","ciphertext":"base64url"}
```

IDs are UUIDv4 or random 18-byte identifiers; accepted syntax is `[A-Za-z0-9_-]{16,64}`.
The timestamp is integer Unix seconds and must be within 90 seconds of the receiver's clock.
Authenticated additional data is exactly the UTF-8 string below (no trailing newline):

```text
openplate/v2\n{context}\n{id}\n{timestamp}
```

Keys are derived with [HKDF-SHA256](https://cryptography.io/en/stable/hazmat/primitives/key-derivation-functions/#hkdf):
IKM = UTF-8 bytes of the random secret string, salt = UTF-8 `openplate/v2/hkdf-sha256`,
info = UTF-8 `openplate/v2/{context}`, output length = 32 bytes. Secrets are generated with
`secrets.token_urlsafe(32)` (256 bits of randomness), not human passwords.

Contexts separate request/response keys, offers, devices, requests and response statuses:

| Message | Context |
| --- | --- |
| Pairing request | `pairing/request/{offer_id}` |
| Pairing response | `pairing/response/{offer_id}/{request_id}/200` |
| Device request | `device/request/{webhook_id}` |
| Device response | `device/response/{webhook_id}/{request_id}/{HTTP_status}` |

A response for a different request or HTTP status fails authentication. No plaintext response,
redirect or protocol downgrade is accepted by the new client. Fixed cross-language vectors are in
`tests/fixtures/encrypted_transport_v2.json`; nonces in that fixture are test-only.

## Pairing

The trusted HA screen presents:

```text
openplate://pair?version=2&pairing_url=...&offer_id=...&key=...&expires_at=...
```

The public offer ID is a random 18-byte identifier. Its independent temporary secret key is 32 random
bytes encoded as base64url. The offer is held only in HA memory, expires after at most ten minutes,
and is removed after the first authenticated exchange. The QR contains no permanent credentials.
The app rejects expired QR codes and old v1 codes, then POSTs to `pairing_url`:

```json
{"offer_id":"public-offer-id","envelope":{"version":2,"id":"...","timestamp":0,"nonce":"...","ciphertext":"..."}}
```

The **key is never transmitted over HTTP**. Decrypted request content must equal
`{"action":"pair","offer_id":"public-offer-id"}`. Invalid ciphertext does not consume an offer.
The successful response is encrypted with the temporary key and contains the v1 device configuration
schema, including the fresh permanent device secret and observation endpoint. A successful response
lost on the network requires a new offer; retrying the consumed offer is rejected. Confirm the HA QR
screen to activate the staged device configuration/key. A restart cancels pending offers.

## Device channel

POST encrypted envelopes to the paired observation webhook for both configuration and observations.
The device root secret is the `webhook_secret` field, retained under its old name for storage compatibility.
New entries and re-pairings persist `transport_version=2` and reject plaintext requests.

Decrypted configuration requests contain `schema_version=1`, `event_type=device.configuration`,
and the paired `device_id`. The response contains configuration plus `session_id`, a fresh random
value generated for each HA entry setup/reload. This session is encrypted, not a public bearer token.
The app obtains it before delivering events, caches it while monitoring, and refreshes on an authenticated
428 response. It also refreshes configuration periodically on the home screen.

Plate observations use the existing v1 event payload plus `session_id`. HA validates the envelope,
envelope freshness, device ID, session, schema and replay ID before emitting events. The observation
timestamp itself is currently parsed but not age-limited; see the security review dated 2026-10-19.
Recorded observations from
an earlier HA runtime cannot pass the new session check. Exact request replays get an encrypted 409;
the app makes a fresh envelope on retry and keeps the stable event ID. HA returns encrypted
`{"accepted":true,"duplicate":true}` for already accepted event IDs in its current 90-second
deduplication window. Fresh events receive encrypted `{"accepted":true}`. Invalid authentication
returns only a generic plaintext error; the app treats that as a failure, never a successful delivery.

Replay/event caches are in memory and bounded by time. Legitimate retries after server restart may
be delivered again; this is not persistent exactly-once delivery. Session binding prevents a passive
network recorder from doing that retry itself. Plate matching alone must not authorize physical access.

## Optional motion metadata (development worktree)

New HA configurations advertise `capabilities: ["motion_v1"]`. Only after authenticated negotiation
does the app attach a `motion` object to a v1 observation. Without this capability it keeps the
existing observation shape, allowing staged upgrades without plaintext or frame-upload fallback.

```json
{"direction":"approaching","dx":0.01,"dy":0.0,"scale_rate":0.08,"samples":4,"span_seconds":3.0}
```

Directions are `unknown`, `stationary`, `approaching` or `receding`. The vector is measured in image
widths/heights per second; scale rate is a relative linear expansion rate per second, not metric depth
velocity. Unknown estimates use null vector/rate values. HA rejects unknown motion fields, non-finite
or out-of-bounds numbers, and classified estimates with insufficient sample count/time span.
The metadata is still a client assertion, not a proof of motion or an instruction to control a door.
No actuator target is accepted from the phone. Legacy `garage_entity_id` metadata is no longer emitted;
HA exposes per-plate presence/direction sensors and calls no actuator services. No bounding boxes
or camera frames are transmitted in observation messages. Growing plate size maps to `arrival`, shrinking to `departure`.
Observation timestamps must be timezone-aware and within 90 seconds of HA time, even inside a
fresh encrypted envelope; stale observations cannot refresh presence.

## Transport and trust boundaries

HA HTTP is restricted to local names (unqualified, `.local`, `.lan`, `.home.arpa`), RFC1918 IPv4,
loopback/link-local IPs, and IPv6 ULA/link-local. Public addresses require HTTPS. Explicitly configured
local URLs take priority; HA's network helper discovers its local URL otherwise. An unknown address
falls back to a confirmation form suggesting `http://homeassistant.local:8123`, not a claim of discovery.
The address can be corrected in **Configure → Change Home Assistant address**.

The iOS app declares local-network access and `NSAllowsLocalNetworking` without globally disabling ATS.
It retains normal certificate checks for HTTPS. IPs, endpoints, sizes and timing remain visible on HTTP;
encrypted payloads protect configuration secrets and plate contents, not traffic metadata or availability.
Open the QR from a trusted HA interface: compromising or modifying that screen can compromise pairing.
Keep QR codes private. There is no forward secrecy if root keys or recorded QR keys are later exposed.

Existing HTTPS entries may temporarily accept old HMAC clients, but HTTP never accepts that plaintext
path. Update both components and re-pair to rotate keys and enforce encrypted-only transport. Keys on
iOS reside in Keychain; HA uses its normal host storage. Since v0.7.0 the mobile app performs inference
locally and sends no images to a separate recognition server. The optional development/reference API
is outside this mobile device channel.

## Optional camera JPEG capability

`camera_jpeg_v1` in authenticated device configuration advertises camera support.
The phone only sends images after the user enables HA live view. Messages use the
existing v2 device encryption contexts, replay checks, device identity and fresh server
session. Plaintext camera requests are rejected.

`camera.frame` carries `schema_version: 1`, `device_id`, `session_id`, an ISO-8601 UTC
`timestamp`, and `jpeg` (standard base64). Maximum JPEG size is 165,000 bytes on the
sender, 220,000 base64 characters on the receiver; dimensions must be at most 640×640.
The encrypted HTTP request limit is 400 KiB; legacy plaintext messages retain 16 KiB.
The phone sends at most two frames/second with one encoding/upload in flight and no queue.
Replies are encrypted acknowledgements with `accepted: true`. A 428 refreshes the session
and drops the old frame; the next callback supplies a new one.

`camera.stopped` carries the same fields except `jpeg` and clears the memory buffer.
Camera timestamps must increase strictly and be within ten seconds of HA time, so an
out-of-order image cannot replace a newer image or undo a stop. Only the latest image
is kept, separate from plate events. It expires after ten seconds without a new image.
OpenPlate does not persist images. HA serves camera images through its standard camera
API; browser transport security and camera access control are supplied by HA.
