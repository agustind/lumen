# CLAUDE.md

## Releasing

1. Bump `VERSION` (semver) and commit with the changes; push `main`.
2. Build, sign, notarize and package:
   ```sh
   export SIGN_IDENTITY="Developer ID Application: DEMUX S.A.S. (4637X2WX3Q)"
   scripts/build-app.sh --standalone && NOTARY_PROFILE=dondo scripts/make-dmg.sh
   ```
   `dondo` is the `notarytool` keychain profile. Notarization takes a few minutes.
3. Publish `build/Lumen-<version>.dmg` as GitHub release `v<version>` (`gh release create`),
   with notes in the same format as earlier releases: "What's new", "Install", "Requirements".
4. Install locally: quit Lumen, replace `/Applications/Lumen.app` with `build/Lumen.app`, relaunch.
