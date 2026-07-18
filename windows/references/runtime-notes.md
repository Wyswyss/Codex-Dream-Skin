# Runtime notes

## Secure Windows lifecycle

- The launcher discovers the current `OpenAI.Codex` package on every run and accepts only a registered, non-development package whose `SignatureKind` is `Store`. It does not patch Appx, `WindowsApps`, `app.asar`, or the official signature.
- Node.js 22 or newer is required. The resolved runtime's real `process.execPath` and version are recorded even when PATH points at a shim.
- The Node supervisor directly spawns the exact discovered `ChatGPT.exe` with `--remote-debugging-pipe`, `shell: false`, and inherited anonymous handles for Chromium's NUL-delimited CDP protocol. It does not start a TCP listener, query a localhost HTTP endpoint, use WebSocket transport, or fall back to a network debugging mode.
- The supervisor must remain alive for the full themed session. It owns the only CDP transport, injects the existing CSS / renderer / image payload, checks renderer markers, and reapplies after navigation or renderer reload. Closing the supervisor closes the pipe; Electron then exits that themed Codex instance. Restore relies on this lifetime relationship before reopening Codex normally.
- Codex must be fully closed before secure launch. This prevents Electron's single-instance handoff from routing the request to an existing process that did not inherit the private handles. The shortcut asks for restart consent; CLI callers must close the app or explicitly authorize `-RestartExisting`.

## State and verification

- Runtime files live under `%LOCALAPPDATA%\CodexDreamSkin`. The persistent state records the random session ID, registered Appx full / family names and install root, exact Codex executable, Node and injector paths, PIDs, process start times, and handshake / status paths.
- The injector writes handshake and health JSON by same-directory atomic replacement. Status contains only the session / process identifiers, skin version, target IDs, structural markers, layout verification result, `app:` identity flags, per-target `lastVerifiedAt`, error summary, and `updatedAt`; it does not include window titles, routes, page text, prompts, or thread content.
- `verify-dream-skin.ps1` accepts status only when it is valid local JSON, matches the random session ID and recorded host / Codex PIDs, has a recent heartbeat, reports a freshly verified `app:` target with a passing renderer result and positive layout dimensions, and both processes still match their exact recorded identities. Reload clears the previous result before reinjection. Stale or mismatched status fails closed.
- This session binding and freshness protect against stale files, PID reuse, and accidental process mistakes. The status file is not cryptographically signed and does not authenticate against a malicious process already running as the same Windows user.
- Secure verification cannot attach a second CDP client to an anonymous inherited pipe. `-ScreenshotPath` is therefore unsupported. Treat automated Verify as a process / session / marker check and complete visual signoff manually in the running app.
- Cleanup stops a recorded process only when all available identity evidence matches. An unverifiable record is preserved and the operation stops instead of guessing which process to terminate. Startup rollback deletes new evidence only after both the exact supervisor and Codex child are confirmed gone; otherwise it preserves a recovery state.

## Security boundary

- Inherited anonymous pipes remove the unauthenticated localhost CDP endpoint and prevent LAN access by construction. There is no port selection, listener ownership, browser endpoint discovery, or TCP compatibility path in secure launch.
- This is risk reduction, not an absolute sandbox. Malware already able to execute as the same Windows user may be able to duplicate process handles, inject into Node or Codex, alter files writable by that user, or observe the renderer by other means. Do not treat the theme as protection from a compromised account.
- Renderer JavaScript and CSS are trusted code in this model. The bundled Windows skin uses only reviewed local files and an embedded data URL, and their exact SHA-256 values are pinned in the injector. Hashes and token scans are a review gate, not a JavaScript sandbox; review a resource diff before updating a hash, and do not introduce remote CSS imports, remote image URLs, or unreviewed injection scripts when swapping artwork.
- The Node parent is intentionally not detached. Do not convert it into a broadly accessible named pipe or service, and do not keep Codex alive after losing the validated supervisor / pipe relationship.

## Configuration and updates

- `config.toml` is read from raw bytes as strict UTF-8, written without BOM through same-directory atomic replacement, and backed up byte-for-byte. Only known appearance keys in `[desktop]` are eligible for selective edits or restore.
- Install requires Codex to be closed. Writes stage the temporary file first, compare the destination through a handle that denies ordinary concurrent writers, then conditionally replace it; shortcut files are staged and rolled back with the config if their commit fails. A process that already holds an unusually permissive handle or ignores this tool's lock protocol can still race user-owned files, so the comparison is not advertised as a cryptographic or filesystem-wide CAS. Quoted keys and table-header comments are supported; escaped target keys, multiline strings / arrays, dotted target keys, duplicate target keys, or conflicting `[desktop.*]` tables fail unchanged.
- Exact recovery is explicit and preserves a copy of the replaced current file. With `-RecoverConfigBackup`, an invalid state can be archived byte-for-byte and bypassed only after every registered Codex process is confirmed closed. Completed restore backups are retained as `config.restored-*.toml`, allowing reinstall to capture a fresh baseline.
- An exclusive lock-file handle under `%LOCALAPPDATA%\CodexDreamSkin` prevents this tool's install, start, restore, and verify operations from racing across console and RDP sessions for the same account.
- Store updates are supported by discovering the registered package on every launch. Saved paths are eligible for automatic process control only after full name, family name, install root, executable path, PID, start time, and launch arguments are revalidated. An active unverified old path requires manual closure.
- Renderer DOM changes can still break injection after a Codex update. The supervisor fails verification instead of weakening transport checks; update the selectors / payload, run automated tests, and repeat live-Windows signoff.

## Live signoff limitations

Automated tests can validate framing, state parsing, configuration preservation, payload construction, and renderer logic in mocks. They cannot prove Store process ownership on a user's machine, Windows handle inheritance, Electron pipe-disconnect behavior in the installed build, current Codex DOM compatibility, or final appearance. Complete every applicable check in `qa-inventory.md` on Windows before release.
