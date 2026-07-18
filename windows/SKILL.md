---
name: codex-dream-skin
description: Apply, launch, verify, repair, update, or restore a full decorative skin for the Windows Codex desktop app. Use when the user asks for a Codex theme that goes beyond official color settings, wants the pink-purple Dream/Fiona-style interface, needs the skin reapplied after a Codex update, or needs a safe rollback without modifying WindowsApps or app.asar.
---

# Codex Dream Skin

Apply a reversible renderer skin to the official Store-installed Codex app. The Windows secure path launches `ChatGPT.exe` with Chromium's inherited `--remote-debugging-pipe`; it does not open a TCP listener, expose an unauthenticated localhost port, or fall back to port mode. Never replace or take ownership of files under `WindowsApps`.

## Workflow

1. Install Node.js 22 or newer, close every Codex process, then run `scripts/install-dream-skin.ps1` once. It safely sets matching official base colors, saves a byte-exact configuration baseline, and creates launch / restore shortcuts.
2. Run `scripts/start-dream-skin.ps1`. It dynamically resolves the current, non-development `OpenAI.Codex` package with `SignatureKind=Store`, then starts the exact executable through the Node supervisor. The shortcut asks before restarting an already-open Codex app; CLI callers must explicitly add `-RestartExisting`.
3. Leave the Node supervisor running. It owns the inherited CDP pipe, applies the existing CSS / image / renderer payload, and reapplies the skin after navigation or renderer reload. Closing or killing the supervisor closes that themed Codex instance; there is deliberately no TCP fallback.
4. Run `scripts/verify-dream-skin.ps1` after launch. Verification checks a fresh, atomically written status record bound to the current session, a fresh per-target `app:` identity / layout result, plus the recorded Node and Store Codex process identities. A missing hero, native composer, sidebar skin, injection marker, stale result, or identity mismatch is failure.
5. Inspect the running app against `references/qa-inventory.md`. Secure mode cannot open a second CDP connection for screenshots, so `-ScreenshotPath` is unsupported. Verify both the home screen and a normal task manually on a live Windows machine before signing off.
6. Run `scripts/restore-dream-skin.ps1` to stop the verified supervisor, let pipe disconnect close the themed Codex instance, and reopen Codex normally. Add `-RestoreBaseTheme` to restore only saved appearance keys, `-RecoverConfigBackup` for explicit byte-for-byte recovery of a damaged config, or `-Uninstall` to delete shortcuts. A completed config restore archives that install's backup so a later install captures a fresh baseline.

## Guardrails

- Preserve the official executable, Store package identity and signature, user threads, pets, plugins, and authentication state. Do not patch Appx, WindowsApps, `app.asar`, or official binaries.
- Spawn the exact discovered executable with `shell: false`, the private pipe as inherited handles, and no `--remote-debugging-port` / `--remote-debugging-address`. Pipe startup or validation failure must fail closed; clean up only exact processes, and preserve recovery state whenever full rollback cannot be proven.
- Treat the Node supervisor and its child Codex process as one lifetime. Do not detach the supervisor, replace the inherited pipe with a named network service, or introduce a TCP compatibility fallback.
- Do not use the full reference screenshot as a fake whole-window overlay. It is only a cropped hero / polaroid asset; all controls remain live Codex controls.
- Keep the reference image confined to the single top banner and decorative crop. Keep the cards below it as native Codex suggestion buttons with native labels / icons.
- Attach the "选择项目" treatment to Codex's real project-selector toolbar and keep the current project button clickable; never draw a disconnected replacement.
- Keep decorative layers `pointer-events: none` and keep real buttons, navigation, and composer above them.
- Treat renderer JavaScript and CSS as executable local theme code. Reuse the reviewed bundled assets; do not add remote `@import` / `url()` resources or third-party injection scripts without a separate review.
- On app updates, rerun install and launch; the scripts discover the current Appx package dynamically. A recorded executable is eligible for process control only while its full name, family name, install root, path, PID, start time, and command line still match the registered Store package.
- Verify status must match the random session ID and recorded host / Codex PIDs, be parseable as strict local JSON, report a recent heartbeat, and contain a passing renderer result. It is evidence for accidental-staleness and PID-reuse protection, not cryptographic authentication against a malicious same-user process.
- Anonymous inherited pipes remove the unauthenticated localhost endpoint, but they do not defend against malware that can already execute as the same Windows user, duplicate process handles, or inject code into another process.
- Preserve `config.toml` as strict UTF-8. Never use encoding-dependent whole-file PowerShell reads / writes, silently transcode UTF-16, or overwrite a file that changed after it was read. Ambiguous TOML shapes must fail before writing rather than receive a best-effort rewrite.
- Keep install / start / restore / verify serialized across console and RDP sessions with the per-user exclusive lock-file handle in `common-windows.ps1`.

## Checks

```powershell
powershell -NoProfile -File tests\run-tests.ps1
node --check scripts\pipe-transport.mjs
node --check scripts\injector.mjs
node --check assets\renderer-inject.js
node scripts\injector.mjs --self-test
node scripts\injector.mjs --check-payload
node tests\pipe-transport.test.mjs
node tests\renderer-inject.test.mjs
```

Automated tests cannot prove Store launch behavior, inherited-handle behavior, current Codex DOM compatibility, or final visuals. Complete the live-Windows checks in `references/qa-inventory.md` before release.

## Resources

- `scripts/injector.mjs`: exact Store executable launch, private-pipe CDP session, renderer injection, status heartbeat, verification, and reapplication.
- `scripts/pipe-transport.mjs`: bounded NUL-delimited Chromium pipe framing and flattened CDP session routing.
- `scripts/common-windows.ps1`: Store-package discovery, Node validation, state, fresh-status validation, operation locking, and exact process-identity safety.
- `scripts/config-utf8.ps1`: atomic UTF-8 configuration backup, selective restore, and explicit recovery.
- `assets/dream-skin.css`: full visual layer.
- `assets/renderer-inject.js`: idempotent DOM integration and cleanup.
- `assets/dream-reference.png`: user-provided visual reference used only in cropped decorative regions.
- `references/qa-inventory.md`: required functional, security, and visual signoff coverage.
- `references/runtime-notes.md`: lifecycle, troubleshooting, update behavior, and security boundaries.
- `tests/run-tests.ps1`: configuration, state, recovery, process-identity, payload, and secure-pipe regression checks.
