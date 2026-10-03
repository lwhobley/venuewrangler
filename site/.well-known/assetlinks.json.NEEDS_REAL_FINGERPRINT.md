# assetlinks.json has a placeholder fingerprint, not a real one

`assetlinks.json` in this directory is what makes Android's App Links (the `autoVerify="true"`
intent-filter in `apps/mobile/android/app/src/main/AndroidManifest.xml`) actually verify this
app as the handler for `https://venuewrangler.com/billing` — the Stripe Checkout/Portal
redirect target. Without a real fingerprint here, Android still offers the app as a candidate
via the plain intent-filter, but skips the no-prompt guarantee `autoVerify` is supposed to give
(the OS may show a disambiguation dialog between the browser and the app instead of opening the
app directly).

**To fix:** once there's a real release signing key (there isn't one yet — this whole engagement
has no Android keystore), get its SHA-256 certificate fingerprint:

```bash
keytool -list -v -keystore <your-release-keystore>.jks -alias <your-key-alias>
```

(or, if signing is managed by Play App Signing, pull it from Play Console → Setup → App
signing). Replace `REPLACE_WITH_REAL_RELEASE_SIGNING_CERT_SHA256_FINGERPRINT` in
`assetlinks.json` with that value (format: `AA:BB:CC:...`, colon-separated hex pairs), then
delete this note.
