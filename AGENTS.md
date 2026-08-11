# Repository Guidelines

## Project Structure & Module Organization

Course-Thru (课速通) is a Windows-only Chromium distribution that preloads the ScriptCat (脚本猫) extension and the OCS course assistant, ready to use out of the box. This repository is the "open edition" (self-maintained, GPL v3). Source files live at the repository root:

- `main.go` / `go.mod` — Go launcher (GUI subsystem, no console): reads `config.json`, seeds `profile/` from `profile_seed/` on first run (concurrent copy, 8 workers + 1 MB buffer), then launches Chromium with `--load-extension` and a long list of `--disable-*` switches that turn off Google features. On first run it writes `first_run.flag` immediately and runs a one-shot CDP cleanup in a background goroutine to close ScriptCat's install-success page; later launches stay debug-port-free. **Session restore is disabled**: every launch clears `Default/Sessions*` and passes `--disable-session-crashed-bubble`, so the browser always starts fresh from the default page with no crash-recovery prompt. `loadConfig` always re-appends `extensions/scriptcat` **and `extensions/baidu-search`** (idempotent) so a user-defined extension list can never break the seeded OCS data or the new-tab→Baidu redirect. Launch args also include `--lang=zh-CN` so the UI and the Accept-Language header stay Chinese even when the seeded `Preferences` lacks `intl.accept_languages` (fixed in 1.0.22 — Chaoxing et al. otherwise render in English).
- `build.ps1` — one-shot build pipeline (steps numbered in comments): downloads pinned components (Chromium/ScriptCat) with a system-proxy fallback, injects the extension key, applies branding (brand strings, `ABOUT` copyright, logo/PE icons), trims locale packs, compiles the launcher, generates `profile_seed`, assembles `dist/`, and packages the installer. `-SkipProfile` reuses the existing seed, `-NoNsis` skips the installer without bumping the version, `-Version x.y.z` overrides the version. OCS is vendored locally, never downloaded.
- `gen-profile.mjs` — CDP automation that produces `profile_seed`: enables developer mode and the userScripts toggle, writes OCS directly into ScriptCat's `chrome.storage.local` (enabled by default, with ScriptCat auto-update `checkUpdate: true`), then restarts and verifies. Signal-driven (DOM condition waits + MutationObserver), no fixed sleeps. Metadata parsing tolerates CRLF/LF line endings (it strips `\r` before matching — CRLF checkouts once made every `@version`/`@match` parse fail, showing OCS as version 0.0 in ScriptCat); the verification step re-reads the storage entry and fails the build unless `@version`/`@match` are present (panel-text-only checks are fooled by the fallback name). Launch args include `--lang=zh-CN` to seed the language.
- `patch-branding.py` — build-time replacement of "Chrome for Testing" / "Google LLC." strings inside `locales\*.pak` and `resources.pak` (idempotent).
- `generate-assets.py` / `patch-logo.py` / `patch-icons.py` — generate the full asset set from `logo/logo.png`, replace in-pak product logos, and rebuild PE icon resources for chrome.exe / chrome.dll / chrome_pwa_launcher.exe / the launcher (all idempotent).
- `extensions/ocs.user.js` — vendored OCS userscript (4.15.3); keep in sync with `$OcsTag` in `build.ps1` (mismatch warns but does not block).
- `extensions/baidu-search/` — built-in MV3 extension: sets Baidu as the default search engine (`chrome_settings_overrides.search_provider`) and redirects new blank tabs to Baidu via `background.js`. `background.js` judges **by URL only, never by `openerTabId`** — since Chrome 152, tabs created via the UI (Ctrl+T / plus button) carry a non-null `openerTabId`, so an opener check would wrongly block real user clicks (regression found and fixed in 1.0.16). No `chrome_url_overrides`, so no confirmation dialog; tabs opened from links keep their target URL.
- `course-thru/` — built-in homepage (self-contained `file://`, all relative paths), opened when `defaultUrl` is empty. Contains 10 course-platform quick entries (auto-scaling grid + per-name dynamic font sizing), a top-right version pill (Liquid Glass, version injected at build time by `build.ps1` replacing `v__VERSION__`), and a bottom-left feedback button (Liquid Glass, links to a Feishu form).
- `logo/logo.png` — single source of truth for all branding assets (generated into `assets/`).
- `third-party-licenses/` — license texts of bundled open-source components (OCS=MIT, ScriptCat=GPL v3), kept for attribution compliance.
- `installer.iss` / `stop-browser.ps1` — Inno Setup packaging and uninstall cleanup (desktop icon task is checked by default; uninstall deletes the CfT policy registry key).
- `keys/scriptcat.key` / `keys/baidu-search.key` — committed public keys that fix the extension IDs (ScriptCat=hodgdaljmnbiliahlpcjcpiphnkbmfff, baidu=kjkhdfinhacckmpplnddgcbbpmncmfmk); never delete them or seeded data breaks. `build.ps1` fails loudly rather than regenerating a new key if any goes missing.
- `config.json.example` — reference for the optional config fields (`defaultUrl`, `extraArgs`, `appName`, `extensions`).
- `version.txt` — single source of truth for the version (`x.y.z`); a full build auto-increments the patch number and writes it back.
- `.gitattributes` — repository-wide line-ending policy (`* text=auto eol=lf` plus binary-file whitelist). Prevents Windows checkouts from converting files to CRLF, which once broke gen-profile's OCS metadata parsing. Never relax it for script files.

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

Publishing notes:
- `build.ps1` does **not** produce a portable zip; before a release, package `dist/` manually (e.g. Python `zipfile`, flat `dist` layout, matching the previous portable zip structure).
- **Do not close the browser window that gen-profile opens during a build** — it drives the real Chromium via CDP (dev-mode toggle, storage write, panel verification); closing it aborts the build with `CDP WebSocket 连接已关闭`.
- Do not write bare `@xxx` tokens in release notes — GitHub renders them as user mentions and the release-page Contributors section shows mentioned users (`@match` once rendered as a stray "match" entry). Use backticks (`@match`) instead.

## Coding Style & Naming Conventions

- Go: `gofmt` formatting, standard library only, exported types/functions documented, `Config` fields map to camelCase JSON keys (`defaultUrl`, `extraArgs`).
- Comments and user-facing strings are in Simplified Chinese; identifiers stay in English.
- PowerShell scripts use `$PSScriptRoot`-derived paths (never hardcoded), `$ErrorActionPreference = "Stop"`, and `[build]`-prefixed log output.
- Python build scripts must stay idempotent (re-running after an upgrade re-applies the patch; no-match cases warn instead of failing).

## Security & Key Handling

- Each extension ID is derived solely from its committed public key (`keys/scriptcat.key`, `keys/baidu-search.key`); it is already baked into the shipped `manifest.json`, so end users never need key files. Losing a key changes that extension's ID and invalidates all seeded script data — restore it with `git restore`, never regenerate.
- Private keys (`keys/*_private.pem`) are git-ignored, unused by builds, and needed only for future CRX signing or store publishing. Keep safe local backups; never commit or package them.
- CfT enterprise policies are written under `HKCU\Software\Policies\Google\Chrome for Testing` (a path specific to Chrome for Testing), so they affect only this browser, never the user's regular Chrome. The launcher queries the whole key once and writes only missing/differing values in parallel; the installer cleans the key on uninstall.

## Testing Guidelines

There is no automated test suite, so verify changes manually against the full checklist:

1. First launch opens **exactly one page** — the built-in homepage `course-thru/index.html` (no session-restore windows from the seed-generation run).
2. The ScriptCat icon loads OCS with no errors; developer mode is on and the userScripts toggle is persisted.
3. No `docs.scriptcat.org` page appears on any launch (install_comple / changelog / open-dev).
4. `dist\first_run.flag` appears after the first launch.
5. The default search engine is Baidu (marked "由扩展控制" in settings) and the new-tab page goes straight to Baidu with no confirmation dialog. To reproduce "click the plus button", send a real Ctrl+T keystroke (system-level) or call `chrome.tabs.create({})` inside the Baidu extension's service worker — CDP `Target.createTarget` creates a tab with a non-null opener that the extension correctly ignores, so it will falsely report failure.
6. The homepage shows the version pill (`v<current>`, build-time injected), a clickable feedback button (Feishu form), and all 10 course quick-entries with DeepSeek last; the GSAP entrance animations play for the copyright element and the feedback button (selectors are class-based — `.copyright` was an ID-selector bug fixed in `e85d536`).
7. Course platforms (e.g. Chaoxing) render in **Chinese** (`--lang=zh-CN`; `navigator.language` should be `zh-CN`), and the ScriptCat panel shows OCS **4.15.3** — version `0.0` means the storage metadata is empty (CRLF parse failure, see `gen-profile.mjs` notes).

If `gen-profile.mjs` changed, delete `dist\profile_seed` and regenerate it, then re-run the end-to-end checks above (extension loads cleanly, developer mode on, OCS listed in the ScriptCat panel, no `install_comple` tab).

## Commit & Pull Request Guidelines

Follow the existing Chinese Conventional Commits style, with a scope for the area touched:

```text
docs: 添加交接文档
feat: 支持 config.json 自定义默认页
fix(build): 修正 profile_seed 复制路径
```

Keep the subject under 50 characters and use the body for rationale and trade-offs. PRs should reference the related issue, describe how the change was verified (build output, manual launch), and call out any changes to pinned component versions, `keys/`, or the `third-party-licenses/` set. Never commit `keys/scriptcat_private.pem` or other secrets. The public repo carries `README.md`, `AGENTS.md`, `CLAUDE.md`, `HANDOVER.md` (full handover log, tracked since 2026-08-12), `LICENSE` (GPL v3), and `third-party-licenses/`; local docs (VERSION, BRANDING-PATCH, CONSOLE-POLICY-NOTES, LOGO-REPLACEMENT, OPEN-VERSION-GUIDE) are git-ignored and never pushed.
