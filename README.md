<div align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="R2 Desk icon">
  <h1>R2 Desk</h1>
  <p><strong>Your R2 files. A familiar Mac app.</strong></p>
  <p>A small native file browser for Cloudflare R2.<br>Open folders in tabs. Upload with drag and drop. Keep your place after restart.</p>
  <p>
    <a href="https://github.com/BUSHA/r2desk/actions/workflows/ci.yml"><img src="https://github.com/BUSHA/r2desk/actions/workflows/ci.yml/badge.svg" alt="Build and checks"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&amp;logoColor=white" alt="macOS 14 or later">
    <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&amp;logoColor=white" alt="Swift 5.9 or later">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-orange" alt="MIT license"></a>
  </p>
  <p><a href="#build-and-install">Build and install</a> · <a href="#connect-to-r2">Connect to R2</a> · <a href="CONTRIBUTING.md">Contribute</a></p>
</div>

![R2 Desk with folder tabs, a file list, and the Transfers sidebar](docs/images/r2-desk.png)

<p align="center"><sub>The current app UI with sample connections and files. No account data is shown.</sub></p>

## Why R2 Desk?

R2 Desk keeps common file tasks close at hand. It uses native macOS controls,
works directly with the R2 S3 API, and has no donation prompts.

| Feature | What you can do |
| --- | --- |
| **All your buckets** | Connect to an account and browse its buckets. No bucket name is needed at setup. |
| **Folder tabs** | Open several remote folders at once. Each tab keeps its own location, history, search, and selection. |
| **File controls** | Upload and download files or whole folders. Create folders, rename files, and delete items. |
| **Quick Look** | Double-click a file to preview a temporary local copy. |
| **Transfers sidebar** | Show or hide progress and results. Resize the panel or stop the current transfer. |
| **Saved sessions** | Restore tabs, tab order, and the selected folder after restart. |
| **Native Mac UI** | Use drag and drop, context menus, keyboard shortcuts, search, and sortable columns. |
| **Keychain storage** | Keep access keys in macOS Keychain. No separate server or third-party packages are needed. |

## Build and install

You need **macOS 14 or later** and Apple Command Line Tools with **Swift 5.9 or later**.
The app builds for the processor of the Mac that runs the build script.

Install the tools if needed:

```sh
xcode-select --install
```

Then build the app:

```sh
git clone https://github.com/BUSHA/r2desk.git
cd r2desk
bash scripts/build-app.sh
open "dist/R2 Desk.app"
```

Drag **R2 Desk.app** from `dist` to **Applications** to install it.
The script also creates `dist/R2-Desk.zip` for distribution.

These builds have a local ad hoc signature. They are **not notarized**.
The CI workflow builds separate Apple silicon and Intel packages. CI packages are
build artifacts, not signed public releases. See the [release guide](docs/RELEASING.md)
for the remaining distribution steps.

## Connect to R2

1. Create an R2 API token in the [Cloudflare dashboard](https://developers.cloudflare.com/r2/api/tokens/).
2. Select **Admin Read only** to browse and download, or **Admin Read & Write** to change files.
3. Copy the **S3 access key ID** and **secret access key**.
4. In R2 Desk, select **Add R2 connection**. Enter a name, your account ID, and the two keys.
5. Select the storage location, then select **Connect**.
6. Double-click a bucket to open its files.

Object-only keys cannot list buckets. A Cloudflare dashboard API token is not an
S3 access key. The app checks bucket access before it saves the connection.

Use **Default** for standard buckets, including buckets with a Europe location hint.
Use **EU**, **US**, or **FedRAMP** for buckets in that jurisdiction. Each connection
shows the buckets at its selected endpoint. You can save several connections.

Right-click a connection to edit it, remove it, or open its bucket list in a new tab.

## Everyday controls

- Double-click a folder to open it. Double-click a file to preview it.
- Right-click a bucket or folder and select **Open in New Tab**.
- Drop files or folders into the file list to upload them.
- Select items and use **Download** to save them to your Mac.
- Select a column header to sort by **Name**, **Size**, or **Modified**. Folders stay first.
- Use Search to filter names in the current folder.
- Use the path bar, or go up from a bucket root, to return to the bucket list.
- Select **Transfers** to show or hide the right sidebar. Drag its divider to resize it.

| Shortcut | Action |
| --- | --- |
| `⌘T` | New tab at the current location |
| `⌘W` | Close the current tab when more than one is open |
| `⇧⌘N` | Add R2 connection |
| `⌘U` | Upload |
| `⌘D` | Download selected items |
| `⌘R` | Refresh |
| `⌘↑` | Parent folder |
| `⌘[` / `⌘]` | Back / Forward |
| `⌘Delete` | Delete selected items, with confirmation |
| `⌘J` | Show or hide Transfers |

## Privacy and file safety

The app connects directly to your selected Cloudflare R2 endpoint over HTTPS.
It has no analytics or separate backend. Both S3 keys stay in macOS Keychain.
Connection names, account IDs, storage locations, and tab state stay in local
UserDefaults. The app does not print access keys in logs.

Upload replacement requires confirmation. Conditional requests help prevent the
replacement of a file that changed since the check. Folder downloads reject unsafe
local paths and do not follow symbolic links.

Read [SECURITY.md](SECURITY.md) to report a security issue privately.

## Current limits

- **5 GiB per file** for upload and file rename. Multipart upload and transfer resume are not included.
- Folder upload and download include nested and empty folders. Folder rename is not included.
- Quick Look downloads a temporary copy. Local edits do not sync to R2. Buckets are not mounted as disks.
- Rename copies a file, then deletes the source. This is not atomic. The app checks
  the source ETag before and after the copy. Another client can still change the source
  before deletion. Destination copy conditions are an R2 beta feature.
- **R2 has no Trash.** Folder deletion includes its contents. Files already transferred
  or deleted stay in that state if an operation stops or fails.
- Folder and multiple-file downloads need a destination without files at the same paths.
  A single-file download uses the macOS Save dialog for replacement approval.
- Symbolic links inside uploaded folders are skipped. Remote keys with unsafe local
  paths cannot be downloaded as folder contents.
- Transfer history lasts for the current app session. Tabs for removed connections are not restored.

## Development

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

The check runner uses mock HTTP responses. It needs no R2 keys and makes no live R2 requests.
It covers request signing, XML parsing, pagination, permissions, tab state, safe paths,
rename failures, and transfers. See [CONTRIBUTING.md](CONTRIBUTING.md) for the code map and workflow.

The scripts select an installed SDK for the running macOS version when available.
Set `R2DESK_SDK_PATH` to use another SDK. The Swift package and executable keep their
original internal name, `R2Man`; the app name is **R2 Desk**.

## License

[MIT](LICENSE) © 2026 BUSHA and contributors.

R2 Desk is an independent project. It is not an official Cloudflare app.
Cloudflare and R2 are trademarks of Cloudflare, Inc.
