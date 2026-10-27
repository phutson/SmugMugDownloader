# SmugMug Downloader

> **This application was created with [Claude Code](https://claude.com/claude-code)**, Anthropic's AI coding assistant.

SmugMug Downloader is a native macOS app that downloads **every photo (and optionally every video) from your own SmugMug account** at original resolution. It saves them to a folder you choose, keeping the same folder → album layout you have on SmugMug.

```
SmugMug                                   Your Mac
───────                                   ────────
Family/                                   <chosen folder>/Family/
  2024/                                     2024/
    Summer Trip (album)        ──────▶        Summer Trip/IMG_0001.jpg, ...
Weddings (album)                          <chosen folder>/Weddings/DSC_1234.jpg, ...
```

## Features

- Signs in with SmugMug's official OAuth flow. Your SmugMug password is entered only on SmugMug's own website and never touches this app.
- Downloads originals and mirrors your SmugMug folder and album structure.
- Lets you pick the top-level download folder.
- Shows status: how many images are left to download and the percent complete.
- Can be resumed: files already on disk at the right size are skipped, so you can stop and re-run, or run it later to pick up new uploads.
- Retries automatically on rate limits and server errors.
- Stores credentials in your macOS Keychain.

## Requirements

- macOS 13 (Ventura) or later
- Xcode or the Swift command-line tools (Swift 5.9+) to build
- A SmugMug account and a free SmugMug API key

## Get a SmugMug API key (one time)

SmugMug's API does not accept a username and password, so the app needs an API key to act on your behalf:

1. Go to https://api.smugmug.com/api/developer/apply and apply for a key. Personal-use keys are approved right away.
2. Copy the **API Key** and **API Secret**.

## Build

```bash
git clone https://github.com/phutson/SmugMugDownloader.git
cd SmugMugDownloader
./build-app.sh
```

This creates `build/SmugMug Downloader.app`. Double-click it, or drag it to `/Applications`.

For development, you can instead open `Package.swift` in Xcode and press Run.

## Usage

1. **SmugMug Account:** paste your API key and secret and click **Sign In with SmugMug…**. Your browser opens SmugMug. Log in there and approve read access.
2. SmugMug shows a **6-digit code**. Enter it in the app and click **Verify**. You only need to do this once; the sign-in is saved in your Keychain.
3. **Download Folder:** click **Choose…** and pick the folder to download into. Turn **Include videos** on or off.
4. Click **Download Everything**.
   - The app first **scans** all your folders and albums to count the images.
   - Then it **downloads**. The Status panel shows the percent complete, images left to download, images downloaded, images already on disk, and failures.
5. To resume an interrupted run or pick up new photos later, click **Download Everything** again. Files that are already downloaded are skipped.

## Details

- Remote `Folder/Sub Folder/Album/photo.jpg` becomes `<chosen folder>/Folder/Sub Folder/Album/photo.jpg`.
- Duplicate names in the same album or folder get ` (2)`, ` (3)` suffixes.
- `/` and `:` in names are replaced with `-`.
- Four files download at a time.
- The app is signed only for local use (ad hoc). If macOS asks to allow Keychain access after a rebuild, choose **Always Allow**.

## Project layout

| File | Purpose |
| --- | --- |
| `Sources/SmugMugDownloader/OAuth1.swift` | OAuth 1.0a (HMAC-SHA1) request signing |
| `Sources/SmugMugDownloader/SmugMugClient.swift` | SmugMug API v2 client, sign-in flow, retries |
| `Sources/SmugMugDownloader/Downloader.swift` | Scans the folder/album tree and downloads files |
| `Sources/SmugMugDownloader/AppModel.swift` | App state, sign-in, progress tracking |
| `Sources/SmugMugDownloader/ContentView.swift` | The main window |
| `Sources/SmugMugDownloader/Keychain.swift` | Credential storage |
| `AppBundle/Info.plist`, `build-app.sh` | Packaging as a `.app` |

## Disclaimer

This is an independent project and is not affiliated with or endorsed by SmugMug. Use it only to download content from your own account.
