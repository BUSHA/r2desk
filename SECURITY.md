# Security

## Supported versions

Security fixes target the latest source on the default branch. There is no separate
support period for older builds. Update before you report a possible issue.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/BUSHA/r2desk/security/advisories/new)
when it is available. Include:

- The affected version or commit.
- Steps to repeat the issue with sample files.
- The expected and actual results.
- The possible effect and any proposed fix.

Do not put vulnerability details or credentials in a public issue. If private reporting
is unavailable, open an issue that asks the maintainer for a private contact method.
Include no vulnerability details in that issue. There is no guaranteed response time.

## Data handling

R2 Desk stores S3 credentials in macOS Keychain. Connection names, account IDs,
storage locations, and tab state are saved in UserDefaults. Preview files use a
local temporary folder. Network requests go directly to the selected R2 endpoint
through URLSession with HTTPS and AWS Signature Version 4.

The app has no analytics or separate server. Automated checks use synthetic keys
and mock responses. R2 access is not needed in CI.

If a key was exposed, revoke it in Cloudflare and create a new key. Remove the exposed
key from all public content. Deleting the latest file does not remove Git history.

Read the [README limits](README.md#limitations) before changing important files.
