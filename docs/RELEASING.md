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
CI does not publish a release. The separate `Build release` workflow has write
permission. It attaches app packages to an existing published release.

## Release steps

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/Info.plist`.
2. Move the relevant changelog items into the new version section.
3. Run `bash scripts/test.sh` and `bash scripts/build-app.sh` from a clean checkout.
4. Confirm CI passes on both architectures. Check the UI and file operations with
   disposable files in a test bucket. Never put R2 keys in CI secrets for these checks.
5. Push the source changes, including `.github/workflows/release.yml`, to the default branch.
6. Create a version tag at that commit. The tag must match the app version in
   `scripts/Info.plist`. For version `1.2.2`, use `v1.2.2`.
7. Create a GitHub release for that tag. Add the changelog notes and state that the
   apps use an ad hoc signature and are not notarized. Publish the release through
   the GitHub website or your local `gh` login.
8. Check the `Build release` workflow. Both jobs must pass. Each job checks the
   version, runs the core checks, builds the app, verifies its signature and CPU,
   and attaches an app ZIP file to the release. Checksums are used for package checks.

For version `1.2.2`, the release gets these files:

- `R2-Desk-1.2.2-arm64.zip`.
- `R2-Desk-1.2.2-x86_64.zip`.

The workflow starts on `release: published`, like Keywheel. Saving a draft does
not start it. The release is visible before the app uploads finish. If a job fails,
fix the cause and rerun the failed job. An upload replaces existing files with the
same names. The workflow uses GitHub's automatic token. No personal token or R2
access keys are needed in repository secrets.

To make the same package locally after a build, run:

```sh
bash scripts/package-release.sh
```

The current build script uses an ad hoc signature. It does not use Developer ID,
notarization credentials, or a universal binary. CI artifacts are separate host builds.
Do not label these apps as notarized.

Developer ID signing and notarization need a separate build setup. To add that
support, follow [Apple's distribution guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
Recreate the ZIP files after signing and stapling. Verify notarization and generate
new checksums for the final ZIP files.

## Screenshot

`docs/images/r2-desk.png` shows the production views with sample connections and files.
The screenshot fixture is separate from the app and is not part of this repo.
Use synthetic data for future screenshots. Do not show real keys, account IDs,
private bucket names, or private files.
