# QA inventory

## User-visible claims

1. The home screen visibly matches the reference mood: one cropped pink-purple starry hero, Fiona portrait crop, signature / brand treatment, native Codex suggestion cards, polaroid, and skinned native composer.
2. The sidebar is blush glass rather than merely changing the accent color.
3. All real Codex controls remain interactive; the skin is not a screenshot overlay.
4. The skin survives route changes and renderer reloads while the Node supervisor remains alive.
5. The official Store package, WindowsApps contents, signature, and `app.asar` remain unchanged.
6. Windows CDP travels only through inherited anonymous pipes. Secure launch creates no TCP debugging listener and has no port-mode fallback.
7. Restore closes the private-pipe session and themed Codex process before reopening the official app normally; install / restore / reapply can be repeated.
8. Pipe mode reduces exposure but is not claimed to defend against malware already executing as the same Windows user.

## Functional checks

- Home feature card: click one card and confirm the real composer is populated or the normal action occurs.
- Project selector: click the real project chip under the "选择项目" label and confirm the native project menu opens.
- Sidebar: open a real task, then return to New Task.
- Composer: type text, verify caret and readability, then clear it without sending.
- Reapply: navigate between New Task and a normal task, then trigger a normal renderer reload if available. Confirm the injection marker and visual treatment return, and Verify reports a newly refreshed passing result.
- Pet overlay: open a desktop pet and confirm its auxiliary window stays transparent with no skin background or decoration layer behind it.
- Supervisor lifetime: identify the recorded Node supervisor, close it through the supported restore / stop path, and confirm the themed Codex process exits rather than continuing without the validated pipe owner.
- Restore / reapply cycle: restore, confirm the app reopens without injected DOM / CSS or private debugging arguments, then start again and confirm the skin returns.
- Update resilience: resolve the current `OpenAI.Codex` Appx location dynamically for every launch. A versioned path saved for cleanup must be revalidated against the registered package full / family identity before any process is stopped.
- Restart consent: an existing normal Codex window is never force-closed without explicit CLI authorization or shortcut confirmation.
- Config safety: Chinese project names, LF / CRLF choice, quoted target keys, table-header comments, and unrelated TOML sections survive install and selective restore. Ambiguous target shapes fail unchanged, exact recovery keeps a copy of the replaced current file, and install refuses both registered and state-recorded old Codex processes.

## Transport and identity checks

- Inspect the launched Codex command line: it contains `--remote-debugging-pipe` and contains neither a remote-debugging port nor an address flag.
- Confirm no new TCP listener belongs to the themed Codex or supervisor. A pipe initialization failure must stop the launch instead of retrying with a network endpoint.
- Confirm the Node supervisor is the direct owner of the inherited pipe handles and the recorded Codex child. Its real executable path, injector path, PID, start time, session ID, handshake path, and status path must match state.
- Confirm Codex's executable path, PID, start time, launch arguments, Appx full name, family name, install root, Store signature kind, and non-development status all match before process control.
- Wait beyond the allowed status age or copy a status file from another session. Verify must reject stale or session-mismatched data.
- Tamper the host PID, Codex PID, process start time, executable path, or session ID in state. Cleanup must not stop an unrelated / reused process; it must preserve the unverifiable state and require manual handling.
- Corrupt, truncate, or replace handshake / status JSON during a read. Verification must fail clearly without guessing or weakening identity checks; a later complete atomic update may recover.
- Confirm `-ScreenshotPath` fails with an explicit secure-mode unsupported message and does not start another client or expose a listener.
- Close Codex normally and confirm its pipe closes and the supervisor exits without reconnecting elsewhere or rapidly growing logs.

## Visual checks

- 1280x820 initial home: hero, four native cards, real project selector, and composer are all visible without horizontal scrolling.
- Narrower window: accept Codex's native responsive reduction to two or three suggestion cards; no essential control is covered and the polaroid may intentionally hide.
- Normal task: messages remain readable and composer does not overlap content.
- Inspect the sidebar, header, hero edges, card labels, composer controls, scrollbar, ribbon, and bottom-right decoration.
- Reject black / transparent sidebar artifacts, clipped cards, duplicated or disconnected project labels, rasterized native controls, weak contrast, or decorations intercepting clicks.
- Because secure Verify cannot capture through a second CDP connection, record the Windows build, Store Codex version, window size, and human reviewer result manually. Do not publish screenshots containing customer or thread data.

## Failure and concurrency checks

- Start with Codex already open: the shortcut requests consent and a noninteractive start fails unless restart was explicitly authorized.
- Start after Codex updates: package discovery and injection work without patching installed files. If the renderer DOM changed, launch fails verification and closes the private session rather than weakening security checks.
- Force failures before handshake publication, after handshake, during first injection, and during status verification. Confirm explicit supervisor / child cleanup. When both exits are proven, only the new evidence is removed and a normal official launch returns; when either exit cannot be proven, recovery state and evidence remain and Codex is not guessed or silently reopened.
- Navigate an attached main target from `app://` to HTTPS and simulate renderer reload. The session must invalidate and detach before payload execution; a previous passing result must not remain healthy during reapply.
- After one successful target, keep every target unhealthy for 30 seconds. The private session must close rather than refresh stale success forever.
- Start two operations concurrently from one session and from console plus RDP for the same account. The second must fail clearly without changing configuration, state, or processes.
- Fail each shortcut staging / commit step. Confirm the original config and every pre-existing shortcut are restored byte-for-byte, or that an incomplete rollback is reported without overwriting a concurrent change.
- Corrupt `state.json`, close every registered Codex process, then run explicit exact config recovery. Confirm the corrupt state is archived unchanged; ordinary Restore must still fail closed on the same corrupt state.
- Remove or upgrade Node after installation, then Restore. Exact recorded process identity and configuration recovery should still work without trusting a different Node on PATH.
- Test malformed and oversized pipe frames in the transport harness; the connection must close, destroy both streams, and reject pending commands.

## Automated checks

- `tests/run-tests.ps1`: PowerShell AST parsing, strict UTF-8 / no-BOM writes, UTF-16 rejection, LF / CRLF preservation, concurrent-write detection, exact backup / recovery, `[desktop]`-scoped restore, ambiguous TOML rejection, non-ASCII paths, Appx / state identity, argument quoting, per-target session freshness, payload construction, private-pipe-only static assertions, and renderer isolation for transparent auxiliary windows.
- `tests/pipe-transport.test.mjs`: NUL framing across fragmented and coalesced reads, flattened session routing, invalid JSON, size limits, timeout, close handling, and pending-request rejection.
- `tests/renderer-inject.test.mjs`: idempotent main-window injection, auxiliary-window cleanup, and reapplication when a target becomes a complete Codex shell.
- `node --check` for `scripts/pipe-transport.mjs`, `scripts/injector.mjs`, and `assets/renderer-inject.js`, plus injector `--self-test` and `--check-payload`.

## Required live-Windows signoff

Automated checks do not establish Store launch behavior, Windows inherited-handle behavior, Electron shutdown on pipe disconnect, current Codex renderer compatibility, or visual quality. Release only after the current Store package passes the functional, transport / identity, visual, failure, Restore, and reapply checks above on a real Windows machine.
