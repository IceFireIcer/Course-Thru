# Repository Guidelines

## Project Structure & Module Organization

Course-Thru (课速通) is a Windows-only Chromium distribution that preloads the ScriptCat (脚本猫) extension and the OCS course assistant, ready to use out of the box. This repository is the "open edition" (self-maintained, GPL v3). Source files live at the repository root:

- `main.go` / `go.mod` — Go launcher (GUI subsystem, no console): reads `config.json`, seeds `profile/` from `profile_seed/` on first run (concurrent copy, 8 workers + 1 MB buffer), then launches Chromium with `--load-extension` and a long list of `--disable-*` switches that turn off Google features. On first run it writes `first_run.flag` immediately and runs a one-shot CDP cleanup in a background goroutine to close ScriptCat's install-success page; later launches stay debug-port-free. **Session restore is disabled**: every launch clears `Default/Sessions*` and passes `--disable-session-crashed-bubble`, so the browser always starts fresh from the default page with no crash-recovery prompt. `loadConfig` always re-appends `extensions/scriptcat` so a user-defined extension list can never break the seeded OCS data.
- `build.ps1` — one-shot build pipeline (steps numbered in comments): downloads pinned components (Chromium/ScriptCat) with a system-proxy fallback, injects the extension key, applies branding (brand strings, `ABOUT` copyright, logo/PE icons), trims locale packs, compiles the launcher, generates `profile_seed`, assembles `dist/`, and packages the installer. `-SkipProfile` reuses the existing seed, `-NoNsis` skips the installer without bumping the version, `-Version x.y.z` overrides the version. OCS is vendored locally, never downloaded.
- `gen-profile.mjs` — CDP automation that produces `profile_seed`: enables developer mode and the userScripts toggle, writes OCS directly into ScriptCat's `chrome.storage.local` (enabled by default, with ScriptCat auto-update `checkUpdate: true`), then restarts and verifies. Signal-driven (DOM condition waits + MutationObserver), no fixed sleeps.
- `patch-branding.py` — build-time replacement of "Chrome for Testing" / "Google LLC." strings inside `locales\*.pak` and `resources.pak` (idempotent).
- `generate-assets.py` / `patch-logo.py` / `patch-icons.py` — generate the full asset set from `logo/logo.png`, replace in-pak product logos, and rebuild PE icon resources for chrome.exe / chrome.dll / chrome_pwa_launcher.exe / the launcher (all idempotent).
- `extensions/ocs.user.js` — vendored OCS userscript (4.15.3); keep in sync with `$OcsTag` in `build.ps1` (mismatch warns but does not block).
- `extensions/baidu-search/` — built-in MV3 extension: sets Baidu as the default search engine (`chrome_settings_overrides.search_provider`) and redirects new blank tabs to Baidu via `background.js` (no `chrome_url_overrides`, so no confirmation dialog).
- `course-thru/` — built-in homepage (self-contained `file://`, all relative paths), opened when `defaultUrl` is empty.
- `logo/logo.png` — single source of truth for all branding assets (generated into `assets/`).
- `third-party-licenses/` — license texts of bundled open-source components (OCS=MIT, ScriptCat=GPL v3), kept for attribution compliance.
- `installer.iss` / `stop-browser.ps1` — Inno Setup packaging and uninstall cleanup (desktop icon task is checked by default; uninstall deletes the CfT policy registry key).
- `keys/scriptcat.key` — committed public key that fixes the extension ID; never delete it or seeded data breaks. `build.ps1` fails loudly rather than regenerating a new key if it goes missing.
- `config.json.example` — reference for the optional config fields (`defaultUrl`, `extraArgs`, `appName`, `extensions`).
- `version.txt` — single source of truth for the version (`x.y.z`); a full build auto-increments the patch number and writes it back.

Build outputs are git-ignored: `dist/` (portable build), `dist-installer/` (setup EXE), `.tools/` (component downloads and caches). The old hand-curated `Build-Product/` delivery folder has been removed; deliverables are `dist/` + `dist-installer/` only.

## Build, Test, and Development Commands

```powershell
# Full build: download components -> inject key -> branding -> compile -> seed profile -> installer
powershell -ExecutionPolicy Bypass -File build.ps1

# Portable build only (no installer, version not bumped)
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis

# Skip seed-profile regeneration (reuse existing dist\profile_seed)
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipProfile

# Manually pin a milestone version
powershell -ExecutionPolicy Bypass -File build.ps1 -Version 1.1.0
```

Run the result by launching `dist\Course-Thru.exe`. Component versions (Chromium 152.0.7977.13, ScriptCat v1.4.0, OCS 4.15.3) are pinned at the top of `build.ps1`; bump them there and regenerate `profile_seed`. There is no test suite — the build plus the manual launch checklist below is the verification loop. `build.ps1` itself must keep its UTF-8 BOM: PowerShell 5.1 decodes the Chinese comments from the BOM, and losing it breaks parsing.

## Coding Style & Naming Conventions

- Go: `gofmt` formatting, standard library only, exported types/functions documented, `Config` fields map to camelCase JSON keys (`defaultUrl`, `extraArgs`).
- Comments and user-facing strings are in Simplified Chinese; identifiers stay in English.
- PowerShell scripts use `$PSScriptRoot`-derived paths (never hardcoded), `$ErrorActionPreference = "Stop"`, and `[build]`-prefixed log output.
- Python build scripts must stay idempotent (re-running after an upgrade re-applies the patch; no-match cases warn instead of failing).

## Security & Key Handling

- The extension ID is derived solely from the committed public key (`keys/scriptcat.key`); it is already baked into the shipped `manifest.json`, so end users never need key files. Losing the key changes the ID and invalidates all seeded script data — restore it with `git restore`, never regenerate.
- The private key (`keys/scriptcat_private.pem`) is git-ignored, unused by builds, and needed only for future CRX signing or store publishing. Keep a safe local backup; never commit or package it.
- CfT enterprise policies are written under `HKCU\Software\Policies\Google\Chrome for Testing` (a path specific to Chrome for Testing), so they affect only this browser, never the user's regular Chrome. The launcher queries the whole key once and writes only missing/differing values in parallel; the installer cleans the key on uninstall.

## Testing Guidelines

There is no automated test suite, so verify changes manually against the full checklist:

1. First launch opens **exactly one page** — the built-in homepage `course-thru/index.html` (no session-restore windows from the seed-generation run).
2. The ScriptCat icon loads OCS with no errors; developer mode is on and the userScripts toggle is persisted.
3. No `docs.scriptcat.org` page appears on any launch (install_comple / changelog / open-dev).
4. `dist\first_run.flag` appears after the first launch.
5. The default search engine is Baidu (marked "由扩展控制" in settings) and the new-tab page goes straight to Baidu with no confirmation dialog.

If `gen-profile.mjs` changed, delete `dist\profile_seed` and regenerate it, then re-run the end-to-end checks above (extension loads cleanly, developer mode on, OCS listed in the ScriptCat panel, no `install_comple` tab).

## Commit & Pull Request Guidelines

Follow the existing Chinese Conventional Commits style, with a scope for the area touched:

```text
docs: 添加交接文档
feat: 支持 config.json 自定义默认页
fix(build): 修正 profile_seed 复制路径
```

Keep the subject under 50 characters and use the body for rationale and trade-offs. PRs should reference the related issue, describe how the change was verified (build output, manual launch), and call out any changes to pinned component versions, `keys/`, or the `third-party-licenses/` set. Never commit `keys/scriptcat_private.pem` or other secrets. The public repo carries `README.md`, `AGENTS.md`, `LICENSE` (GPL v3), and `third-party-licenses/`; local docs (HANDOVER, VERSION, BRANDING-PATCH, CONSOLE-POLICY-NOTES, LOGO-REPLACEMENT, OPEN-VERSION-GUIDE) are git-ignored and never pushed.
