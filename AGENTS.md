# Repository Guidelines

## Project Structure & Module Organization

Course-Thru (课速通) is a Windows-only Chromium launcher preloading the ScriptCat extension and the OCS course assistant. Source files live at the repository root:

- `main.go` / `go.mod` — Go launcher: reads `config.json`, seeds `profile/` from `profile_seed/` on first run, then launches Chromium with `--load-extension`. On first run it writes `first_run.flag` and uses one-shot CDP cleanup to close ScriptCat's install-success page; later launches stay debug-port-free.
- `build.ps1` — one-shot build: downloads pinned components (Chromium/ScriptCat), injects the extension key, applies the welcome-page patch (UTF-8 safe), compiles the launcher, packages the installer. OCS is vendored locally, never downloaded.
- `gen-profile.mjs` — CDP automation that produces `profile_seed`: enables developer mode and the userScripts toggle, writes OCS directly into ScriptCat's `chrome.storage.local` (enabled by default), then restarts and verifies. Signal-driven (DOM condition waits), no fixed sleeps.
- `extensions/ocs.user.js` — vendored OCS userscript (4.15.3); keep in sync with `$OcsTag` in `build.ps1`.
- `installer.iss` / `stop-browser.ps1` — Inno Setup packaging and uninstall cleanup.
- `keys/scriptcat.key` — committed public key that fixes the extension ID; never delete it or seeded data breaks. `build.ps1` fails loudly rather than regenerating a new key if it goes missing.
- `config.json.example` — reference for the optional config fields.

Build outputs are git-ignored: `dist/` (portable build), `dist-installer/` (setup EXE), `.tools/` (component downloads and caches).

## Build, Test, and Development Commands

```powershell
# Full build: download components -> inject key -> compile -> seed profile -> installer
powershell -ExecutionPolicy Bypass -File build.ps1

# Portable build only (no installer)
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis

# Skip seed-profile regeneration (reuse existing dist\profile_seed)
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipProfile
```

Run the result by launching `dist\Course-Thru.exe`. Component versions (Chromium, ScriptCat, OCS) are pinned at the top of `build.ps1`; bump them there and regenerate `profile_seed`. There is no test suite — the build and manual launch below are the verification loop.

## Coding Style & Naming Conventions

- Go: `gofmt` formatting, standard library only, exported types/functions documented, `Config` fields map to camelCase JSON keys (`defaultUrl`, `extraArgs`).
- Comments and user-facing strings are in Simplified Chinese; identifiers stay in English.
- PowerShell scripts use `$PSScriptRoot`-derived paths (never hardcoded), `Stop` error handling, and `[build]`-prefixed log output.

## Security & Key Handling

- The extension ID is derived solely from the committed public key (`keys/scriptcat.key`); it is already baked into the shipped `manifest.json`, so end users never need key files.
- The private key (`keys/scriptcat_private.pem`) is git-ignored, unused by builds, and needed only for future CRX signing or store publishing. Keep a safe local backup; never commit or package it.

## Testing Guidelines

There is no automated test suite, so verify changes manually:

1. Run the build, then confirm the launcher copies `profile_seed` into a fresh `profile/`.
2. Launch `dist\Course-Thru.exe` and check the ScriptCat icon loads OCS with no errors.
3. Confirm no `docs.scriptcat.org/docs/use/install_comple` tab opens on first or later launches, and that `first_run.flag` appears in the program root after the first launch.
4. If `gen-profile.mjs` changed, regenerate `profile_seed` and verify end to end: extension loads (no errors), developer mode is on, OCS appears in the ScriptCat panel, and no `install_comple` welcome tab opens.

## Commit & Pull Request Guidelines

Follow the existing Conventional Commits style in Chinese, with a scope for the area touched:

```text
docs: 添加交接文档
feat: 支持 config.json 自定义默认页
fix(build): 修正 profile_seed 复制路径
```

Keep the subject under 50 characters and use the body for rationale and trade-offs. PRs should reference the related issue, describe how the change was verified (build output, manual launch), and call out any changes to pinned component versions or `keys/`. Never commit `keys/scriptcat_private.pem` or other secrets.
