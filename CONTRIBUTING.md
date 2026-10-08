# Contribute to R2 Desk

Small, focused changes are welcome. Keep the app simple and use native macOS controls.
Be respectful in issues and reviews. Explain the problem and the expected result.

## Start

1. Fork the repo and create a branch for your change.
2. Build with `bash scripts/build-app.sh`.
3. Make your change. Use sample data and mock HTTP responses.
4. Run `bash scripts/test.sh` for changes to storage or session behavior.
5. Run `bash scripts/build-app.sh` for app changes.
6. Open a pull request. Describe the change and the checks you ran.

For UI changes, include a screenshot with sample file names. Check the changed control
in both light and dark appearance when possible. State any check you could not run.
For documentation changes, check local links and commands. A full app test is not needed.

## Code map

| Path | Purpose |
| --- | --- |
| `Sources/R2Core/` | R2 requests, SigV4 signing, XML parsing, models, safe paths, and saved tab state |
| `Sources/R2Desk/` | SwiftUI views, app state, transfers, Quick Look, and Keychain access |
| `Tests/R2CoreTests/` | Standalone check runner with synthetic data and mock HTTP responses |
| `scripts/` | Build, checks, SDK selection, app metadata, and icon tools |
| `Assets/` | App icons and their creation notes |
| `docs/` | Screenshot and release guide |

The check runner is an executable target named `R2CoreChecks`. Use `scripts/test.sh`;
`swift test` does not run these checks. There are no third-party Swift packages.

The scripts keep compiler caches in `.build`. Use `R2DESK_SDK_PATH` if you need to
select a specific installed SDK. Build output goes to `dist`.

## Keep changes safe

- Never commit access keys, account data, private bucket names, or local preference files.
- Use synthetic credentials in tests. Do not include keys in logs or screenshots.
- Keep network checks independent of a real R2 account.
- Preserve exact object key bytes, pagination, and safe local path checks.
- Keep confirmation for replacement and deletion.
- Test request failures and changed objects when you change file operations.
- Keep sample and screenshot fixtures out of the production app.
- Do not add a package unless it solves a clear problem.

## Report a bug

Use the bug report template. Include the app and macOS versions, your Mac processor,
steps to repeat the issue, and the expected result. Remove private data from screenshots
and errors. For a security issue, follow [SECURITY.md](SECURITY.md).

## Pull request notes

Keep one purpose per pull request. Include the reason for a change, its effect,
and the checks that support it. For a new feature, discuss large scope changes in an
issue before implementation. Contributions use the [MIT license](LICENSE).
