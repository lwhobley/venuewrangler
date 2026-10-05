# assetlinks.json fingerprints

`assetlinks.json` currently lists the SHA-256 of the **upload key** generated for this app
(`apps/mobile/android/upload-keystore.jks`, gitignored — back it up with `key.properties`).
That is enough for sideloaded/internal builds signed with it.

If the app is distributed through Google Play with **Play App Signing** (the default), Play
re-signs the release with its own key, and App Links `autoVerify` checks *that* certificate.
Once the app exists in Play Console, copy **App signing key certificate → SHA-256** from
*Setup → App signing* and add it as a second entry in `sha256_cert_fingerprints`.
