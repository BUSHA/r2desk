# R2 Desk

A small native macOS app for Cloudflare R2 files.

## Start

1. Open `dist/R2 Desk.app`.
2. Select **Add R2 connection**.
3. Enter your account ID, access key ID, and secret access key. No bucket name is needed.
4. Select **Connect**. The app loads the bucket list before it saves the connection.
5. Double-click a bucket to open its files.

To install the app, drag `dist/R2 Desk.app` into your Applications folder.
The build is for the Mac that runs the build script. This app needs macOS 14 or later.
The app has a local signature. It is not notarized for public distribution.

## File controls

- Double-click a folder to open it. Double-click a file to use Quick Look.
- Right-click a bucket and select **Open in New Tab**.
- Use **Buckets** in the path bar, or go up from a bucket root, to return to the bucket list.
- Press **⌘T** to open another tab at the current folder.
- Right-click a folder and select **Open in New Tab**.
- Drop files or folders into the file list to upload them. **⌘U** also opens Upload.
- Select files or folders and press **⌘D** to download them.
- Use the folder button next to Search to create a folder.
- Right-click a file to rename it.
- Press **⌘R** to refresh. Press **⌘↑** to open the parent folder.
- Press **⌘Delete** to delete selected files. The app asks first.
- Press **⌘J**, or select the right sidebar button, to show or hide Transfers.
  Drag the divider to resize it. Use **Stop** to cancel the current operation.
- Search checks file names in the current folder.

Each tab keeps its own bucket, folder, search text, and selection. Select any part of a tab
to open it. Tabs and their close buttons show a hover state.
A connection is for an account and a storage location. The bucket list includes all pages.
Existing connections keep their names and saved keys and now open the bucket list.
You can add more connections. Right-click a connection to edit or remove it.

## R2 keys

Create an R2 API token with **Admin Read only** access to list buckets and read files.
Use **Admin Read & Write** access if you also want to upload, rename, or delete files.
Object-only keys cannot list buckets. The app shows this requirement if R2 refuses the list.
Copy its S3 access key ID and secret access key. A Cloudflare dashboard API token alone will not work.
Select **European Union (EU)**, **United States (US)**, or **FedRAMP** to browse buckets
in that jurisdiction. Each connection lists buckets at the selected storage endpoint.
Use **Default** for standard buckets, including buckets with a location hint in Europe.

The app saves both S3 keys in macOS Keychain. It saves connection names, account IDs,
and storage locations in UserDefaults. It does not send keys to another server or print them in logs.

[Cloudflare key guide](https://developers.cloudflare.com/r2/api/tokens/)
· [R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/)
· [R2 copy conditions](https://developers.cloudflare.com/r2/api/s3/extensions/)

## Limits in this version

- Upload and file rename support files up to **5 GiB**. Uploads use one request for each file.
  Multipart upload and transfer resume are not included.
- Folder upload and download include nested folders and empty folders.
  Folder rename is not included.
- Preview downloads a temporary copy. Local edits do not sync to R2.
  This app does not mount the bucket as a disk.
- Upload replacement requires confirmation. Conditional requests prevent a replacement
  when the file has changed since the check.
- Downloads of folders or multiple files need a destination without existing files at
  those paths. A single-file download uses the macOS Save dialog for replacement approval.
- R2 rename uses copy, then delete. This is not one atomic operation. The app checks the
  source checksum before and after the copy. Another client can still change the source
  between the final check and deletion. Do not rename a file while another client writes to it.
  Destination copy conditions are an R2 beta feature.
- R2 has no Trash. Folder deletion includes its nested files. If an operation fails or
  stops, files already transferred or deleted stay in that state. Refresh shows the result.
- Remote keys that contain unsafe local paths cannot be downloaded as folder contents.
  Local symbolic links are not followed. Symbolic links inside uploaded folders are skipped.
- Open tabs, tab order, the selected tab, folder history, search text, and selection stay
  after restart. The app reloads the file lists and removes selections for missing files.
  Tabs for removed connections are not restored. Transfer history stays in the current app session.

## Build and test

Install Apple Command Line Tools if needed: `xcode-select --install`.
No third-party packages are needed.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open "dist/R2 Desk.app"
```

The build script creates the app and `dist/R2-Desk.zip`. It uses the SDK for the running
macOS version when available. Set `R2DESK_SDK_PATH` to select another installed SDK.

The tests cover signing, XML responses, bucket and folder pages, account permissions,
saved connection migration, bucket navigation, names with Unicode and special
characters, safe download paths, copy failure, rename, and file transfers.
Tests use mock HTTP responses. They do not use your real R2 account.

Before using important files, connect a test bucket and check upload, download, rename,
and delete with a small test file. Live R2 access needs your keys in the app.
