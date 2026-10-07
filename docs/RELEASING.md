# Public repo and release guide

## Repo setup

The local files are ready for review. Publishing and GitHub settings are separate steps.

- Review the existing Git history before changing repo visibility. Older `AGENTS.md`
  versions include a personal note that is removed from the current file. Keep the
  original repo local if you choose to publish from a fresh history.
- Use the repo name `r2desk` and description: **A small native macOS file browser for Cloudflare R2. Tabs, Quick Look, and simple file transfers.**
- Suggested topics: `macos`, `swift`, `swiftui`, `cloudflare-r2`, `s3`, `file-manager`.
- Enable Issues and private vulnerability reporting.
- Enable Dependabot alerts and GitHub secret scanning when available.
- Protect the default branch. Require a review and the two **Build and checks** jobs.
- Check the first CI run on Apple silicon and Intel. Local validation does not prove both builds work.

The workflow has read-only repository permissions. Actions use fixed commit IDs.
Dependabot checks those pins each week. It uses `pull_request` with no repo secrets.
CI does not deploy or publish a release.

## Release steps

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/Info.plist`.
2. Move the relevant changelog items into the new version section.
3. Run `bash scripts/test.sh` and `bash scripts/build-app.sh` from a clean checkout.
4. Confirm CI passes on both architectures. Check the UI and file operations with
   disposable files in a test bucket. Never put R2 keys in CI secrets for these checks.
5. For public distribution, sign the app with a Developer ID certificate and the
   hardened runtime. Submit it to Apple's notarization service and staple the ticket.
   Follow [Apple's distribution guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
6. Recreate the zip after signing and stapling. Keep the app bundle structure and executable permissions.
7. Verify the signature and notarization. Generate a SHA-256 checksum for each final zip.
8. Create a version tag and release with the changelog notes, architecture-specific
   packages, and checksums. These are manual publishing steps.

The current build script uses an ad hoc signature. It does not use Developer ID,
notarization credentials, or a universal binary. CI artifacts are separate host builds.
Do not label them as notarized or as release packages before those steps are complete.

## Screenshot

`docs/images/r2-desk.png` shows the production views with sample connections and files.
The screenshot fixture is separate from the app and is not part of this repo.
Use synthetic data for future screenshots. Do not show real keys, account IDs,
private bucket names, or private files.
