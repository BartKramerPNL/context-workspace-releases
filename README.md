# Context Workspace releases

Downloads and updates for **Context Workspace**, a desktop app for macOS and Windows that gives AI agents (Claude,
GitHub Copilot) a window on a folder of Markdown documentation kept in git. You sign in with your own Claude or
GitHub Copilot subscription. Everything else the app needs ships inside the installer.

The app's source code is private. This repository holds the
[releases](https://github.com/BartKramerPNL/context-workspace-releases/releases) and the workflow that builds them:
it builds the app from a tagged source commit, tests the installers and the update path on macOS and Windows, and
publishes the release only when every test passes. Releases are immutable: once published, their files cannot
change. The installed app checks this repository for updates and needs no GitHub account for it.

## Download

Open the [latest release](https://github.com/BartKramerPNL/context-workspace-releases/releases/latest) and download
the file for your computer:

| Your computer | File |
|---|---|
| Mac with Apple silicon (M1 or later) | `context-workspace-<version>-mac-arm64.dmg` |
| Mac with an Intel processor | `context-workspace-<version>-mac-x64.dmg` |
| Windows 10 or 11, 64-bit | `context-workspace-<version>-win-x64-setup.exe` |

Not sure which Mac you have? Apple menu > **About This Mac**: "Chip Apple M…" means Apple silicon, "Processor
Intel" means Intel. macOS 13 or later is needed.

The other files in a release:

| File | What it is |
|---|---|
| `*.zip`, `*.blockmap`, `latest-mac.yml`, `latest.yml` | Used by the app's updater |
| `SHA256SUMS.txt` | Checksums of all files (see [Verify a download](#verify-a-download)) |
| `git-<version>.tar.xz`, `git-for-windows-<version>-source.tar.gz`, `dugite-native-<version>-source.tar.gz` | Source code of the Git the app bundles (GPLv2) |

## First launch on macOS

The app is signed with its own certificate, but not by a paid Apple developer account, so macOS asks you to allow
it once:

1. Open the DMG and drag **Context Workspace** to **Applications**.
2. Open the app from **Applications**. macOS says it cannot check the app for malware. Click **Done** (not **Move
   to Trash**).
3. Open **System Settings > Privacy & Security** and scroll down to **Security**. Next to the message about Context
   Workspace, click **Open Anyway**, confirm with your password or Touch ID, and click **Open Anyway** once more.

On macOS 13 and 14 you can instead Control-click the app in **Applications**, choose **Open**, and click **Open**
again.

You only do this once. Updates are signed with the same certificate, so they install without asking, and
permissions you granted (such as the microphone) stay in place. If a release switches silent updates off for macOS,
the app offers each new version as a download instead (see [Updates](#updates)).

If macOS says the app **is damaged**, the download is incomplete or was changed: delete it, download it again and
[verify it](#verify-a-download).

## First launch on Windows

The installer is not signed with a paid certificate, so Windows warns you once:

1. If your browser says the file is not commonly downloaded, keep it. In Edge: **…** > **Keep** > **Show more** >
   **Keep anyway**.
2. Run the installer. When **Windows protected your PC** appears, click **More info**, then **Run anyway**.
3. The app installs for your user only (no administrator rights needed) into
   `%LOCALAPPDATA%\Programs\context-workspace` and starts.

PCs with **Smart App Control** switched on block unsigned apps entirely; the app cannot be installed there.

## Updates

The app checks for a new version when it starts and downloads it in the background. When the update is ready, it
offers to restart to install it.

On macOS the app shows a banner with a **Downloaden** button instead when it cannot install an update itself, or
when silent updates are switched off for macOS. The button opens the new DMG for your Mac: install it the way you
installed the app the first time, replacing the copy in **Applications**.

When a release switches silent updates off for macOS, Macs on the version before it may fail to install that
release themselves; they then show this banner for it. The release workflow accepts that failure only for such a
release: for any other release, an update that macOS rejects keeps the release from being published.

## Verify a download

Every release has a `SHA256SUMS.txt` with the SHA-256 checksum of each file. In the folder with your download and
`SHA256SUMS.txt`:

```bash
# macOS
shasum -a 256 --check --ignore-missing SHA256SUMS.txt
```

```powershell
# Windows (PowerShell): compare the output with the line for this file in SHA256SUMS.txt
(Get-FileHash .\context-workspace-<version>-win-x64-setup.exe -Algorithm SHA256).Hash
```

Every file also has a [build attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations):
a signed record that it was built by this repository's release workflow. Check it with the
[GitHub CLI](https://cli.github.com/):

```bash
gh attestation verify context-workspace-<version>-mac-arm64.dmg \
  --repo BartKramerPNL/context-workspace-releases \
  --signer-workflow BartKramerPNL/context-workspace-releases/.github/workflows/release.yml
```

On macOS you can also check that an installed app carries the app's certificate:

```bash
codesign -dvv "/Applications/Context Workspace.app" 2>&1 | grep Authority
# Authority=app.contextworkspace.desktop signing
```
