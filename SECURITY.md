# Security and privacy baseline

- Inference is local; the Phase 2 CLI contains no network transmission code.
- Generated annotated images and crops may contain personal data. They are created only at explicitly
  supplied output locations and are ignored by Git by default.
- Model download URLs and caches are currently managed by upstream libraries. Reproducible deployment
  should add pinned artifact hashes before unattended provisioning.
- The iOS client requires HTTPS for frames and webhook events. Recognition uses an API key stored in
  Keychain. Home Assistant requests use HMAC-SHA256, a short timestamp window and one-time nonces.
- HMAC is authentication, not encryption. TLS provides transport encryption. Home Assistant may store
  plate text in its recorder, so recorder retention and access controls remain necessary.
- OCR output is an observation, not an identity proof. It cannot directly authorize physical access.
- Secure pairing and certificate provisioning are still required before production use.
- Debug image retention must remain opt-in and receive a bounded retention policy in later phases.

Report vulnerabilities privately to the future security contact before public disclosure; a project
contact has not yet been established.

