import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  CdpPipeConnection,
  CdpPipeSession,
  NulDelimitedPipeTransport,
} from "./pipe-transport.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const SKIN_VERSION = "1.1.0-secure-pipe.2";
const TARGET_ID_PATTERN = /^[A-Za-z0-9._-]{1,200}$/;
const SESSION_ID_PATTERN = /^[A-Za-z0-9._-]{16,200}$/;
const ZERO_HEALTHY_TARGET_GRACE_MS = 30000;
// These hashes are a review boundary. Update one only after reviewing that asset's exact diff.
const ASSET_SHA256 = Object.freeze({
  "dream-skin.css": "a85bd61d699496928ab19a5d9ea6d1aaaaeedd4bbfb48e37d873854480b53fff",
  "renderer-inject.js": "6d8498150980d95a34768ed63f24a148518e93aebbd3832ee96e7d7c8eaaba75",
  "dream-reference.png": "e6019a268915194e270d9ad4eb44d99c1a43c22c11463137147d9e00428375fc",
});
const UNSAFE_CHILD_ENVIRONMENT_KEYS = new Set([
  "ALL_PROXY",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "NO_PROXY",
  "SSL_CERT_DIR",
  "SSL_CERT_FILE",
]);
const UNSAFE_CHILD_ENVIRONMENT_PREFIXES = [
  "CHROME_",
  "DYLD_",
  "ELECTRON_",
  "LD_",
  "NODE_",
  "OPENSSL_",
];

function parseArgs(argv) {
  const options = {
    mode: "watch",
    codexExe: null,
    handshakePath: null,
    statusPath: null,
    sessionId: null,
    profilePath: null,
    timeoutMs: 45000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--watch") options.mode = "watch";
    else if (argument === "--codex-exe") options.codexExe = path.resolve(argv[++index]);
    else if (argument === "--handshake") options.handshakePath = path.resolve(argv[++index]);
    else if (argument === "--status") options.statusPath = path.resolve(argv[++index]);
    else if (argument === "--session-id") options.sessionId = argv[++index];
    else if (argument === "--profile-path") options.profilePath = path.resolve(argv[++index]);
    else if (argument === "--timeout-ms") options.timeoutMs = Number(argv[++index]);
    else if (argument === "--self-test") options.mode = "self-test";
    else if (argument === "--check-payload") options.mode = "check-payload";
    else throw new Error(`Unknown argument: ${argument}`);
  }

  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1000 || options.timeoutMs > 120000) {
    throw new Error(`Invalid timeout: ${options.timeoutMs}`);
  }
  if (options.mode === "watch") {
    if (!options.codexExe || !path.isAbsolute(options.codexExe)) throw new Error("--codex-exe must be absolute");
    if (!options.handshakePath || !path.isAbsolute(options.handshakePath)) throw new Error("--handshake must be absolute");
    if (!options.statusPath || !path.isAbsolute(options.statusPath)) throw new Error("--status must be absolute");
    if (!SESSION_ID_PATTERN.test(options.sessionId ?? "")) throw new Error("--session-id is invalid");
    if (options.profilePath && !path.isAbsolute(options.profilePath)) throw new Error("--profile-path must be absolute");
  }
  return options;
}

async function writeJsonAtomically(outputPath, value) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const temporary = path.join(
    path.dirname(outputPath),
    `.${path.basename(outputPath)}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`,
  );
  try {
    await fs.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    for (let attempt = 0; ; attempt += 1) {
      try {
        await fs.rename(temporary, outputPath);
        break;
      } catch (error) {
        const transient = ["EACCES", "EBUSY", "EPERM"].includes(error?.code);
        if (!transient || attempt >= 5) throw error;
        await new Promise((resolve) => setTimeout(resolve, 10 * (2 ** attempt)));
      }
    }
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

function assetSha256(name, bytes) {
  let reviewedBytes = bytes;
  if (name.endsWith(".css") || name.endsWith(".js")) {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    // Git may check text assets out with CRLF on Windows; line endings are not executable content.
    reviewedBytes = Buffer.from(text.replace(/\r\n?/g, "\n"), "utf8");
  }
  return createHash("sha256").update(reviewedBytes).digest("hex");
}

export function assertAssetHashes(assets, expectedHashes = ASSET_SHA256) {
  for (const [name, expectedHash] of Object.entries(expectedHashes)) {
    const bytes = assets[name];
    if (!Buffer.isBuffer(bytes)) throw new Error(`Dream Skin asset is missing: ${name}`);
    const actualHash = assetSha256(name, bytes);
    if (actualHash !== expectedHash) {
      throw new Error(
        `Dream Skin asset hash mismatch: ${name}. Review the asset diff before updating ASSET_SHA256.`,
      );
    }
  }
}

async function loadPayload() {
  const assetPaths = {
    "dream-skin.css": path.join(root, "assets", "dream-skin.css"),
    "renderer-inject.js": path.join(root, "assets", "renderer-inject.js"),
    "dream-reference.png": path.join(root, "assets", "dream-reference.png"),
  };
  const [cssBytes, templateBytes, art] = await Promise.all(
    Object.values(assetPaths).map((assetPath) => fs.readFile(assetPath)),
  );
  assertAssetHashes({
    "dream-skin.css": cssBytes,
    "renderer-inject.js": templateBytes,
    "dream-reference.png": art,
  });
  const css = cssBytes.toString("utf8");
  const template = templateBytes.toString("utf8");
  if (/@import\b|url\(\s*["']?(?:https?:|\/\/)/i.test(css)) {
    throw new Error("Dream Skin CSS contains a remote resource");
  }
  if (/\b(?:fetch|[Ww]ebSocket|XMLHttpRequest)\s*\(|\bimport\s*\(|https?:\/\//i.test(template)) {
    throw new Error("Dream Skin renderer contains a network-capable source token");
  }
  const artDataUrl = `data:image/png;base64,${art.toString("base64")}`;
  return template
    .replace("__DREAM_VERSION_JSON__", JSON.stringify(SKIN_VERSION))
    .replace("__DREAM_ART_JSON__", JSON.stringify(artDataUrl))
    .replace("__DREAM_CSS_JSON__", JSON.stringify(css));
}

export function isUnsafeChildEnvironmentKey(key) {
  const upperKey = String(key).toUpperCase();
  return UNSAFE_CHILD_ENVIRONMENT_KEYS.has(upperKey) ||
    UNSAFE_CHILD_ENVIRONMENT_PREFIXES.some((prefix) => upperKey.startsWith(prefix));
}

export function createCodexEnvironment(environment = process.env) {
  const sanitized = { ...environment };
  for (const key of Object.keys(sanitized)) {
    if (isUnsafeChildEnvironmentKey(key)) delete sanitized[key];
  }
  return sanitized;
}

export function isPotentialCodexTarget(targetInfo) {
  return Boolean(
    targetInfo &&
    targetInfo.type === "page" &&
    typeof targetInfo.targetId === "string" &&
    TARGET_ID_PATTERN.test(targetInfo.targetId) &&
    typeof targetInfo.url === "string" &&
    targetInfo.url.startsWith("app://"),
  );
}

export function targetInfoProtocol(targetInfo) {
  if (typeof targetInfo?.url !== "string") return null;
  try {
    return new URL(targetInfo.url).protocol;
  } catch {
    return null;
  }
}

export function classifyTargetTransition(previousTargetInfo, currentTargetInfo) {
  const sameTarget = typeof previousTargetInfo?.targetId === "string" &&
    previousTargetInfo.targetId === currentTargetInfo?.targetId;
  const scopeChanged = sameTarget && (
    previousTargetInfo.type !== currentTargetInfo?.type ||
    previousTargetInfo.url !== currentTargetInfo?.url
  );
  return {
    sameTarget,
    previousProtocol: targetInfoProtocol(previousTargetInfo),
    currentProtocol: targetInfoProtocol(currentTargetInfo),
    invalidate: scopeChanged,
    detach: sameTarget && !isPotentialCodexTarget(currentTargetInfo),
  };
}

async function probeSession(session) {
  return session.evaluate(`(() => {
    const markers = {
      shell: Boolean(document.querySelector('main.main-surface')),
      sidebar: Boolean(document.querySelector('aside.app-shell-left-panel')),
      composer: Boolean(document.querySelector('.composer-surface-chrome')),
      main: Boolean(document.querySelector('[role="main"]')),
    };
    return {
      markers,
      appProtocol: location.protocol,
      appIdentity: location.protocol === 'app:' && markers.shell && markers.sidebar && (markers.composer || markers.main),
      codex: location.protocol === 'app:' && markers.shell && markers.sidebar && (markers.composer || markers.main),
    };
  })()`);
}

async function verifySession(session) {
  return session.evaluate(`(() => {
    const box = (node) => {
      if (!node) return null;
      const rectangle = node.getBoundingClientRect();
      return {
        x: Math.round(rectangle.x),
        y: Math.round(rectangle.y),
        width: Math.round(rectangle.width),
        height: Math.round(rectangle.height),
      };
    };
    const home = document.querySelector('.dream-home');
    const suggestions = home?.querySelector('.group\\\\/home-suggestions') ?? null;
    const cards = suggestions ? [...suggestions.querySelectorAll('button')].map(box) : [];
    const result = {
      appProtocol: location.protocol,
      appIdentity: location.protocol === 'app:' &&
        Boolean(document.querySelector('main.main-surface')) &&
        Boolean(document.querySelector('aside.app-shell-left-panel')) &&
        Boolean(document.querySelector('.composer-surface-chrome') || document.querySelector('[role="main"]')),
      installed: document.documentElement.classList.contains('codex-dream-skin'),
      version: window.__CODEX_DREAM_SKIN_STATE__?.version ?? null,
      expectedVersion: ${JSON.stringify(SKIN_VERSION)},
      stylePresent: Boolean(document.getElementById('codex-dream-skin-style')),
      chromePresent: Boolean(document.getElementById('codex-dream-skin-chrome')),
      chromePointerEvents: getComputedStyle(document.getElementById('codex-dream-skin-chrome') || document.body).pointerEvents,
      homePresent: Boolean(home),
      suggestionsPresent: Boolean(suggestions),
      hero: box(home?.firstElementChild?.firstElementChild?.firstElementChild),
      cards,
      composer: box(document.querySelector('.composer-surface-chrome')),
      sidebar: box(document.querySelector('aside.app-shell-left-panel')),
      viewport: { width: innerWidth, height: innerHeight },
      documentOverflow: {
        x: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        y: document.documentElement.scrollHeight > document.documentElement.clientHeight,
      },
    };
    result.pass = result.appProtocol === 'app:' && result.appIdentity &&
      result.installed && result.version === result.expectedVersion &&
      result.stylePresent && result.chromePresent && result.chromePointerEvents === 'none' &&
      Boolean(result.composer) && Boolean(result.sidebar) &&
      (!result.homePresent || (Boolean(result.hero) &&
        (!result.suggestionsPresent || (result.cards.length >= 2 && result.cards.length <= 4))));
    return result;
  })()`);
}

async function waitForVerifiedSession(session, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastResult = null;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      lastResult = await verifySession(session);
      lastError = null;
      if (lastResult?.pass) return lastResult;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
  if (!lastResult && lastError) throw lastError;
  return lastResult;
}

async function detachSession(connection, sessionId) {
  try {
    await connection.send("Target.detachFromTarget", { sessionId });
  } catch {}
}

async function waitForSpawn(child, timeoutMs = 10000) {
  await new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timeout);
      child.off("spawn", onSpawn);
      child.off("error", onError);
    };
    const onSpawn = () => {
      cleanup();
      resolve();
    };
    const onError = (error) => {
      cleanup();
      reject(new Error(`Codex process could not be launched: ${error.message}`));
    };
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("Codex process launch timed out"));
    }, timeoutMs);
    child.once("spawn", onSpawn);
    child.once("error", onError);
  });
}

async function waitForExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    const finish = (exited) => {
      clearTimeout(timeout);
      child.off("exit", onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    const timeout = setTimeout(() => finish(false), timeoutMs);
    child.once("exit", onExit);
  });
}

async function closeChildProcess(child, connection, transport) {
  if (!child) return;
  if (connection) connection.close(new Error("Private CDP host is stopping"));
  else if (transport) transport.close(new Error("Private CDP host is stopping"));
  else {
    for (const stream of [child.stdio?.[3], child.stdio?.[4]]) {
      try { stream?.destroy(); } catch {}
    }
  }

  if (await waitForExit(child, 5000)) return;
  try { child.kill(); } catch {}
  await waitForExit(child, 5000);
}

async function runWatch(options) {
  await fs.access(options.codexExe);
  if (options.profilePath) await fs.mkdir(options.profilePath, { recursive: true });
  const payload = await loadPayload();
  const launchArguments = ["--remote-debugging-pipe"];
  if (options.profilePath) launchArguments.push(`--user-data-dir=${options.profilePath}`);
  const sessions = new Map();
  const failures = new Map();
  let child = null;
  let transport = null;
  let connection = null;
  let publishStatus = null;
  let stopping = false;
  let childExited = false;
  let firstVerified = false;
  let zeroHealthySince = null;
  let lastHealthCheckAt = 0;
  let terminalError = null;

  const stop = () => { stopping = true; };
  const onChildExit = () => {
    childExited = true;
    stopping = true;
  };
  const onChildError = (error) => {
    if (!terminalError) terminalError = new Error(`Codex process error: ${error.message}`);
    stopping = true;
  };

  const invalidateEntry = (entry, targetInfo = null) => {
    entry.verificationGeneration += 1;
    entry.result = null;
    entry.lastVerifiedAt = null;
    entry.markers = null;
    entry.appProtocol = targetInfoProtocol(targetInfo);
    entry.appIdentity = false;
  };

  const removeSession = (targetId, expectedEntry = null) => {
    const entry = sessions.get(targetId);
    if (!entry || (expectedEntry && entry !== expectedEntry)) return null;
    if (entry?.reapplyTimer) clearTimeout(entry.reapplyTimer);
    invalidateEntry(entry);
    sessions.delete(targetId);
    return entry;
  };

  const isCurrentVerification = (targetId, entry, generation) =>
    sessions.get(targetId) === entry && entry.verificationGeneration === generation;

  const probeAndVerify = async (targetId, entry, { inject, timeoutMs = 10000 }) => {
    if (entry.verifying || sessions.get(targetId) !== entry) return null;
    entry.verifying = true;
    invalidateEntry(entry, entry.targetInfo);
    const generation = entry.verificationGeneration;
    try {
      const probe = await probeSession(entry.session);
      if (!isCurrentVerification(targetId, entry, generation)) return null;
      entry.markers = probe?.markers ?? null;
      entry.appProtocol = probe?.appProtocol ?? null;
      entry.appIdentity = probe?.appIdentity === true;
      if (!probe?.codex || entry.appProtocol !== "app:" || !entry.appIdentity) {
        throw new Error("Target no longer has the Codex app identity");
      }

      if (inject) await entry.session.evaluate(payload);
      const result = inject
        ? await waitForVerifiedSession(entry.session, timeoutMs)
        : await verifySession(entry.session);
      if (!isCurrentVerification(targetId, entry, generation)) return null;
      entry.appProtocol = result?.appProtocol ?? null;
      entry.appIdentity = result?.appIdentity === true;
      if (!result?.pass || entry.appProtocol !== "app:" || !entry.appIdentity) {
        throw new Error(inject
          ? "Injected renderer did not pass visual safety checks"
          : "Renderer verification no longer passes");
      }
      entry.result = result;
      entry.lastVerifiedAt = new Date().toISOString();
      return result;
    } finally {
      entry.verifying = false;
    }
  };

  const scheduleReapply = (targetId, entry) => {
    if (entry.reapplyTimer) clearTimeout(entry.reapplyTimer);
    entry.reapplyTimer = setTimeout(() => {
      entry.reapplyTimer = null;
      if (entry.verifying) {
        scheduleReapply(targetId, entry);
        return;
      }
      probeAndVerify(targetId, entry, { inject: true, timeoutMs: 15000 }).catch((error) => {
        console.error(`[dream-skin] private-pipe reinjection failed for ${targetId}: ${error.message}`);
        const removed = removeSession(targetId, entry);
        if (removed) detachSession(connection, removed.sessionId).catch(() => {});
      });
    }, 250);
  };

  const handleTargetInfoChanged = (targetInfo) => {
    const targetId = targetInfo?.targetId;
    if (!targetId) return;
    failures.delete(targetId);
    const entry = sessions.get(targetId);
    if (!entry) return;
    const transition = classifyTargetTransition(entry.targetInfo, targetInfo);
    entry.targetInfo = targetInfo;
    if (!isPotentialCodexTarget(targetInfo)) {
      invalidateEntry(entry, targetInfo);
      const removed = removeSession(targetId, entry);
      if (removed) detachSession(connection, removed.sessionId).catch(() => {});
      return;
    }
    if (transition.invalidate) {
      invalidateEntry(entry, targetInfo);
      scheduleReapply(targetId, entry);
    }
  };

  const handleEvent = (event) => {
    if (event.method === "Target.targetDestroyed" && event.params?.targetId) {
      removeSession(event.params.targetId);
      failures.delete(event.params.targetId);
      return;
    }
    if (event.method === "Target.detachedFromTarget" && event.params?.sessionId) {
      for (const [targetId, entry] of sessions) {
        if (entry.sessionId === event.params.sessionId) removeSession(targetId);
      }
      return;
    }
    if (event.method === "Target.targetInfoChanged" && event.params?.targetInfo?.targetId) {
      handleTargetInfoChanged(event.params.targetInfo);
      return;
    }
    if (event.method === "Page.loadEventFired" && event.sessionId) {
      for (const [targetId, entry] of sessions) {
        if (entry.sessionId === event.sessionId) {
          invalidateEntry(entry, entry.targetInfo);
          scheduleReapply(targetId, entry);
        }
      }
    }
  };

  const attachTarget = async (targetInfo) => {
    if (!isPotentialCodexTarget(targetInfo) || sessions.has(targetInfo.targetId)) return;
    const failedUntil = failures.get(targetInfo.targetId)?.until ?? 0;
    if (failedUntil > Date.now()) return;

    let sessionId = null;
    let entry = null;
    try {
      const attached = await connection.send("Target.attachToTarget", {
        targetId: targetInfo.targetId,
        flatten: true,
      });
      sessionId = attached.sessionId;
      if (typeof sessionId !== "string" || !sessionId) throw new Error("Target returned no flattened session ID");
      const session = new CdpPipeSession(connection, sessionId);
      await session.send("Runtime.enable");
      await session.send("Page.enable");
      entry = {
        session,
        sessionId,
        targetInfo,
        markers: null,
        result: null,
        lastVerifiedAt: null,
        appProtocol: targetInfoProtocol(targetInfo),
        appIdentity: false,
        reapplyTimer: null,
        verifying: false,
        verificationGeneration: 0,
      };
      sessions.set(targetInfo.targetId, entry);
      const result = await probeAndVerify(targetInfo.targetId, entry, { inject: true, timeoutMs: 20000 });
      if (!result?.pass) throw new Error("Target verification was superseded");
      failures.delete(targetInfo.targetId);
      console.log(`[dream-skin] injected verified Codex target ${targetInfo.targetId} over private pipe`);
    } catch (error) {
      if (entry) removeSession(targetInfo.targetId, entry);
      if (sessionId) await detachSession(connection, sessionId);
      const previous = failures.get(targetInfo.targetId)?.count ?? 0;
      const count = previous + 1;
      const delay = Math.min(30000, 1500 * (2 ** Math.min(count - 1, 4)));
      failures.set(targetInfo.targetId, { count, until: Date.now() + delay });
      if (count === 1 || count % 5 === 0) {
        console.error(`[dream-skin] target ${targetInfo.targetId} was not ready; retrying privately in ${delay}ms`);
      }
    }
  };

  const reconcileTargets = async () => {
    const response = await connection.send("Target.getTargets", { filter: [{ type: "page" }] });
    const targetInfos = Array.isArray(response.targetInfos) ? response.targetInfos : [];
    const activeTargets = new Map(targetInfos
      .filter((target) => typeof target?.targetId === "string")
      .map((target) => [target.targetId, target]));
    for (const [targetId, entry] of [...sessions]) {
      const targetInfo = activeTargets.get(targetId);
      if (!targetInfo || !isPotentialCodexTarget(targetInfo)) {
        const removed = removeSession(targetId, entry);
        if (removed) detachSession(connection, removed.sessionId).catch(() => {});
      } else {
        const transition = classifyTargetTransition(entry.targetInfo, targetInfo);
        entry.targetInfo = targetInfo;
        if (transition.invalidate) {
          invalidateEntry(entry, targetInfo);
          scheduleReapply(targetId, entry);
        }
      }
    }
    for (const targetInfo of targetInfos) await attachTarget(targetInfo);
  };

  try {
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    child = spawn(options.codexExe, launchArguments, {
      shell: false,
      detached: false,
      windowsHide: false,
      cwd: path.dirname(options.codexExe),
      env: createCodexEnvironment(),
      stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"],
    });
    child.once("exit", onChildExit);
    child.on("error", onChildError);
    await waitForSpawn(child);
    if (!child.stdio[3]?.write || !child.stdio[4]?.on) {
      throw new Error("Codex did not inherit the required private CDP pipes");
    }

    transport = new NulDelimitedPipeTransport(child.stdio[3], child.stdio[4]);
    connection = new CdpPipeConnection(transport);
    connection.onEvent(handleEvent);
    publishStatus = async (healthy, error = null) => {
      const targets = [...sessions.entries()]
        .filter(([, entry]) => entry.markers && entry.result && entry.lastVerifiedAt &&
          typeof entry.appProtocol === "string" && typeof entry.appIdentity === "boolean")
        .map(([targetId, entry]) => ({
          targetId,
          markers: entry.markers,
          result: entry.result,
          lastVerifiedAt: entry.lastVerifiedAt,
          appProtocol: entry.appProtocol,
          appIdentity: entry.appIdentity,
        }));
      await writeJsonAtomically(options.statusPath, {
        schemaVersion: 1,
        transport: "pipe",
        sessionId: options.sessionId,
        version: SKIN_VERSION,
        hostPid: process.pid,
        codexPid: child.pid,
        healthy,
        error,
        targets,
        updatedAt: new Date().toISOString(),
      });
    };

    await writeJsonAtomically(options.handshakePath, {
      schemaVersion: 1,
      transport: "pipe",
      sessionId: options.sessionId,
      hostPid: process.pid,
      codexPid: child.pid,
      createdAt: new Date().toISOString(),
    });
    await connection.send("Browser.getVersion");
    await connection.send("Target.setDiscoverTargets", { discover: true });
    const startupDeadline = Date.now() + options.timeoutMs;

    while (!stopping && !connection.closed) {
      await reconcileTargets();
      const now = Date.now();
      if (now - lastHealthCheckAt >= 5000) {
        lastHealthCheckAt = now;
        for (const [targetId, entry] of [...sessions]) {
          if (entry.verifying) continue;
          try {
            await probeAndVerify(targetId, entry, { inject: false });
          } catch {
            const removed = removeSession(targetId, entry);
            if (removed) await detachSession(connection, removed.sessionId);
          }
        }
      }

      const healthy = [...sessions.values()].some((entry) =>
        entry.result?.pass && entry.appProtocol === "app:" && entry.appIdentity === true && entry.lastVerifiedAt);
      if (healthy) {
        firstVerified = true;
        zeroHealthySince = null;
      } else if (firstVerified && zeroHealthySince === null) {
        zeroHealthySince = now;
      }
      await publishStatus(healthy);
      if (!firstVerified && Date.now() >= startupDeadline) {
        throw new Error("No verified Codex renderer became available through the private CDP pipe");
      }
      if (firstVerified && zeroHealthySince !== null &&
          Date.now() - zeroHealthySince >= ZERO_HEALTHY_TARGET_GRACE_MS) {
        throw new Error("No verified Codex renderer remained after the 30-second grace period");
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    if (connection.closed && !stopping) {
      throw new Error("Private CDP pipe closed unexpectedly");
    }
  } catch (error) {
    terminalError = error;
    throw error;
  } finally {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    for (const [targetId, entry] of sessions) {
      if (entry.reapplyTimer) clearTimeout(entry.reapplyTimer);
      if (connection && !connection.closed) await detachSession(connection, entry.sessionId);
      sessions.delete(targetId);
    }
    await closeChildProcess(child, connection, transport);
    child?.off("error", onChildError);
    const finalMessage = terminalError?.message ?? (childExited ? "Codex closed" : "Private pipe host stopped");
    if (publishStatus) await publishStatus(false, finalMessage).catch(() => {});
  }
}

async function runSelfTest() {
  const safeTarget = { type: "page", targetId: "page-123", url: "app://codex/" };
  const unsafeTargets = [
    { ...safeTarget, type: "other" },
    { ...safeTarget, targetId: "page 123" },
    { ...safeTarget, url: "https://example.com/" },
  ];
  if (!isPotentialCodexTarget(safeTarget) || unsafeTargets.some(isPotentialCodexTarget)) {
    throw new Error("Private-pipe target validation self-test failed");
  }
  const unsafeNavigation = classifyTargetTransition(safeTarget, unsafeTargets[2]);
  if (!unsafeNavigation.invalidate || !unsafeNavigation.detach ||
      unsafeNavigation.previousProtocol !== "app:" || unsafeNavigation.currentProtocol !== "https:") {
    throw new Error("Private-pipe navigation scope self-test failed");
  }
  const sanitized = createCodexEnvironment({
    PATH: "safe",
    Node_Options: "--require attacker.js",
    ELECTRON_RUN_AS_NODE: "1",
    NODE_PATH: "C:\\untrusted",
    Chrome_User_Data_Dir: "C:\\untrusted-profile",
    OPENSSL_CONF: "C:\\untrusted-openssl.cnf",
    HTTPS_PROXY: "http://untrusted.invalid",
    LD_PRELOAD: "untrusted.dll",
  });
  if (sanitized.PATH !== "safe" || Object.keys(sanitized).some((key) =>
    isUnsafeChildEnvironmentKey(key))) {
    throw new Error("Codex child environment sanitization self-test failed");
  }
  console.log(JSON.stringify({ pass: true, version: SKIN_VERSION, transport: "pipe" }));
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.mode === "self-test") {
    await runSelfTest();
  } else if (options.mode === "check-payload") {
    const payload = await loadPayload();
    if (payload.includes("__DREAM_CSS_JSON__") || payload.includes("__DREAM_ART_JSON__") ||
        payload.includes("__DREAM_VERSION_JSON__")) {
      throw new Error("Payload placeholders were not fully replaced");
    }
    console.log(JSON.stringify({
      pass: true,
      version: SKIN_VERSION,
      payloadBytes: Buffer.byteLength(payload),
      assetSha256: ASSET_SHA256,
    }));
  } else {
    await runWatch(options);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
