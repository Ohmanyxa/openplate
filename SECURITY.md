# Security and privacy baseline

- Inference is local; the Phase 2 CLI contains no network transmission code.
- Generated annotated images and crops may contain personal data. They are created only at explicitly
  supplied output locations and are ignored by Git by default.
- Model download URLs and caches are currently managed by upstream libraries. Reproducible deployment
  should add pinned artifact hashes before unattended provisioning.
- The iOS client requires HTTPS for camera frames to the separate recognition server. Recognition
  uses an API key stored in Keychain. The HA channel supports local HTTP using application encryption.
- Pairing, HA configuration and plate events use AES-256-GCM with HKDF-SHA256 direction/context keys,
  random 96-bit nonces and authenticated IDs/timestamps. Replies bind the request ID and HTTP status.
  Unauthenticated responses are never treated as acknowledgements. See [the protocol](docs/ENCRYPTED_TRANSPORT.md).
- Home Assistant may store plate text in its recorder, so recorder retention and access controls remain necessary.
- OCR output is an observation, not an identity proof. It cannot directly authorize physical access.
- QR pairing uses a temporary random 256-bit key, held in HA memory with a public offer ID and valid
  for at most ten minutes. The key travels only via the trusted QR scan, never in an HTTP request.
  The offer is consumed after successful authentication. Failed authentication does not consume it.
  A lost successful response requires a new QR. Confirm the configuration in HA after scanning.
- The QR must originate from a trusted HA interface and remain private. OpenPlate does not secure
  the HA browser interface itself. An attacker able to replace the QR in that interface can subvert
  first pairing. HTTPS remains useful for that interface; OpenPlate does not require installing it.
- This PSK protocol has no forward secrecy: exposure of the device key, or a recorded QR key plus
  its recorded pairing response, can expose captured traffic. It has not received an independent audit.
- Device/API keys on iOS are stored in Keychain. HA uses its normal configuration storage; protect
  its host and backups. Recognition-server certificates must still be trusted by the iPhone.
- Replay IDs and event deduplication have a 90-second in-memory window. A fresh server-session ID
  on each entry reload/start additionally rejects recorded plate requests across restarts. Legitimate
  delivery retries across restarts are not an exactly-once guarantee. All encrypted responses prohibit caching.
- Existing HTTPS entries retain legacy HMAC transport until re-pairing; new/re-paired entries reject
  plaintext. HTTP never accepts legacy HMAC transport. Both components must be updated together.
- Debug image retention must remain opt-in and receive a bounded retention policy in later phases.

Report vulnerabilities privately to the future security contact before public disclosure; a project
contact has not yet been established.

