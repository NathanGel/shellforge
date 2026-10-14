# Releasing Shellforge

Ported from AiTerm's `docs/releasing.md`.

## Versions

Releases are numbered `major.minor.patch`: `0.1.0` is the first.
- **patch:** fixes only.
- **minor:** new features.
- **major:** a change that breaks a saved setup.

The tag is `v<version>`. The build number is one more than the number of Shellforge releases on GitHub, so it grows
with every release. Builds from source keep iTerm2's version string, such as `3.7.dev`, and are
marked as development builds: they never offer or install an update.

## One-time setup

- **Signing certificate.**
  1. Keychain Access › Certificate Assistant › Create a Certificate…
  2. Name `Shellforge Release`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*, then Create.
  3. Export a backup: My Certificates › Shellforge Release › Export…, as a `.p12` with a password. Keep it safe.

  A release signed with another certificate cannot update installs signed with this one. Every
  release also keeps the Keychain's "Always Allow" for Shellforge's tokens.
- **GitHub CLI:** `brew install gh`, then `gh auth login`.
- **Xcode 27** and swiftly's Swift 6.4.

## Making a release

From a clean `master` that matches `origin/master`:

    Shellforge/scripts/release.sh 0.1.0

It:
1. checks the branch, the tag, `gh` and the certificate;
2. builds with `make-app.sh` (iTerm2's Deployment configuration, Apple silicon), stamps the version and build number, and signs with the certificate;
3. wraps the app in `build/Shellforge-<version>.dmg` with `make-dmg.sh`, and checks it;
4. pushes the tag and publishes the GitHub release with the DMG attached, as a draft first, so updaters never see a release without its image.

Running Shellforge sees the new version under **Check for Updates…**.

## If a release stops halfway

- **The tag was pushed but there is no release.** Finish it by hand:
  1. Check whether it exists: `gh release view v<version> --repo NathanGel/shellforge`.
  2. If it doesn't, create it: `gh release create v<version> build/Shellforge-<version>.dmg --repo NathanGel/shellforge --draft --verify-tag --title "Shellforge <version>" --generate-notes`.
  3. If the image is missing, upload it: `gh release upload v<version> build/Shellforge-<version>.dmg --repo NathanGel/shellforge`.
  4. Publish it: `gh release edit v<version> --repo NathanGel/shellforge --draft=false`.
- **The `git push` failed.** The tag exists only locally, and a re-run refuses with "v… already exists".
  - Either retry `git push origin v<version>` and continue as above;
  - or remove the local tag with `git tag -d v<version>` and run the release again.

## Development builds

- `Shellforge/scripts/make-app.sh` alone builds `build/Shellforge.app`, marked as a development build.
- Day-to-day work uses the Development configuration from Xcode or `xcodebuild`: see the repository's `CLAUDE.md`.
