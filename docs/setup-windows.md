# Windows setup guide (alpha)

Status: **not tested on a second computer** (waiting for Developer A's owner to follow this guide on their Windows laptop and confirm in the PR).

This guide explains how to install and start JARVIS on Windows 10 or Windows 11. It is written for someone who is not a software developer. If you are a developer and want to build from source, see the last section.

## What to expect in the alpha

- **Typing only today**: voice features (wake word, push-to-talk, speech-to-text, and spoken replies) are not built yet. You talk to JARVIS by typing.
- **No automatic updates**: when a newer build is ready, download and run the new installer by hand.
- **Default icon**: the app uses the default Tauri icon until custom artwork is added.

## 1. Download the Windows installer

JARVIS does not publish public release pages yet. Instead, GitHub builds the Windows installer automatically under the `installers` workflow (`.github/workflows/installers.yml`).

1. Open the repository on GitHub and click **Actions** (not checked in the app).
2. In the left sidebar, click the **installers** workflow (not checked in the app).
3. Open the latest successful workflow run and scroll down to **Artifacts** (not checked in the app).
4. Download **jarvis-windows** (artifacts are kept for 14 days after a run).
5. Open the downloaded `jarvis-windows.zip` file and extract it to a folder on your computer. Inside you will find the Windows installer files (`*-setup.exe` and `*.msi`) and a `SHA256SUMS.txt` file listing their checksums.

## 2. Run the installer and pass Windows SmartScreen

Because JARVIS is an early alpha, the Windows installer is not signed with a paid certificate (decision D-13). Windows SmartScreen will show a warning the first time you run it.

1. Double-click the `*-setup.exe` or `*.msi` installer file you extracted (exact installer prompts are not checked in the app).
2. When Windows SmartScreen shows a warning window ("Windows protected your PC" — not checked in the app), click **More info**.
3. Click **Run anyway**.
4. Follow the installer prompts until setup finishes (not checked in the app).

## 3. Check the Windows microphone privacy setting

Voice input is **not built yet**, so JARVIS does not use your microphone today.

If you want to prepare your Windows microphone setting for when voice is added later (spec §6.7):

1. Open the Windows **Settings** app (not checked in the app).
2. Click **Privacy & security** on Windows 11, or **Privacy** on Windows 10 (not checked in the app).
3. Click **Microphone** (not checked in the app).
4. Make sure **Let apps access your microphone** (and access for desktop apps) is switched on (not checked in the app).

When voice support is turned on in a future build, if Windows blocks microphone access, JARVIS will show **Microphone blocked** (`MIC_PERMISSION_DENIED`) with the hint: "Allow microphone access for JARVIS in your system settings."

## 4. Start JARVIS

1. Open the Windows **Start** menu and click **jarvis** / **JARVIS**, or use the desktop shortcut if the installer created one (not checked in the app).
2. The main **JARVIS** window opens at 1280×720. Compact orb mode, the system tray icon, and starting automatically at login are not built yet.
3. Next, follow [`docs/first-run.md`](first-run.md) to add your API key and try your first commands.

---

## Run from source (for developers)

If you are a developer working on the repository, you need Git, Node.js, pnpm, a Rust toolchain, and the [Tauri 2 prerequisites](https://v2.tauri.app/start/prerequisites/) for Windows.

From the repository folder, run:

```bash
pnpm install
pnpm tauri dev
```

### Optional terminal shortcuts: `jarvis` and `jarvis-mock`

You can install two helper commands so you can start JARVIS from any folder. Open a normal PowerShell or Command Prompt window (do **not** use "Run as administrator") in the repository folder and run:

```bat
.\scripts\install-shortcuts.cmd
```

This writes `jarvis.cmd` and `jarvis-mock.cmd` into `%USERPROFILE%\.local\bin` and adds that folder to your user `PATH` without changing PowerShell's script execution policy. It refuses to overwrite existing files it did not create, and requires the repository path to use plain ASCII characters.

Open a **new** PowerShell or Command Prompt window and type:

| Command       | What it starts                                                                       |
| ------------- | ------------------------------------------------------------------------------------ |
| `jarvis`      | The real app (`pnpm tauri dev`, needs your API key in Settings)                      |
| `jarvis-mock` | The mock backend (`VITE_TRANSPORT=mock`): fake replies, scenario buttons, MOCK badge |

Before starting, each command updates your checkout (`git pull --quiet --ff-only`), but only when you are on `main` with no local changes. Set `JARVIS_NO_UPDATE=1` to skip the update check.

To remove the shortcuts later, run:

```bat
.\scripts\install-shortcuts.cmd -Uninstall
```
