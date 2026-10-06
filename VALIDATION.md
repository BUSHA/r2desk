# Validation

Checked on 6 October 2026, on an Apple silicon Mac with macOS 26.6.2.

- The release app builds with the installed macOS 26.5 SDK.
- All 21 automated checks pass. They use mock HTTP responses. Run `bash scripts/test.sh` to repeat them.
- The app signature and Info.plist are checked after packaging.
- The app links to system libraries. It needs no separate R2 server or third-party runtime.
- The toolbar bucket title uses one line, with space on each side.
- The first screen has an empty connection view when no connection is saved.
- The sidebar has no repeated security message or keyboard guide.
- The app bundle contains PNG and ICNS icons. The PNG also supplies the Dock icon.

Live R2 access needs your account keys. The app checks a connection when you enter
your keys and select Connect.

The app has a local ad hoc signature. Public notarization and Intel builds were not done.
Read README.md for file-size limits and the copy-then-delete behavior of R2 rename.
