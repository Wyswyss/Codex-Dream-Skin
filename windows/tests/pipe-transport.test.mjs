import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  CdpPipeConnection,
  CdpPipeSession,
  NulDelimitedPipeTransport,
} from "../scripts/pipe-transport.mjs";
import {
  assertAssetHashes,
  classifyTargetTransition,
  createCodexEnvironment,
  isPotentialCodexTarget,
} from "../scripts/injector.mjs";

function createPipeFixture(options = {}) {
  const writable = new PassThrough();
  const readable = new PassThrough();
  const outboundChunks = [];
  writable.on("data", (chunk) => outboundChunks.push(Buffer.from(chunk)));
  const transport = new NulDelimitedPipeTransport(writable, readable, options);
  return { outboundChunks, readable, transport, writable };
}

function readOutboundMessages(outboundChunks) {
  const bytes = Buffer.concat(outboundChunks);
  assert.equal(bytes.at(-1), 0, "outbound CDP data must end with a NUL delimiter");
  return bytes
    .subarray(0, -1)
    .toString("utf8")
    .split("\0")
    .map((message) => JSON.parse(message));
}

test("NUL transport reconstructs a frame split across chunks", () => {
  const { readable, transport } = createPipeFixture();
  const messages = [];
  transport.onMessage((message) => messages.push(message));

  readable.write(Buffer.from('{"id":1,"res'));
  assert.deepEqual(messages, []);
  readable.write(Buffer.from('ult":{"ok":true}}'));
  assert.deepEqual(messages, []);
  readable.write(Buffer.from("\0"));

  assert.deepEqual(messages, ['{"id":1,"result":{"ok":true}}']);
  transport.close();
});

test("NUL transport emits multiple frames coalesced in one chunk", () => {
  const { readable, transport } = createPipeFixture();
  const messages = [];
  transport.onMessage((message) => messages.push(message));

  readable.write(Buffer.from('first\0{"method":"Target.targetCreated"}\0third\0'));

  assert.deepEqual(messages, [
    "first",
    '{"method":"Target.targetCreated"}',
    "third",
  ]);
  transport.close();
});

test("flattened sessions send top-level sessionId and route results by command id", async () => {
  const { outboundChunks, readable, transport } = createPipeFixture();
  const connection = new CdpPipeConnection(transport);
  const sessionA = new CdpPipeSession(connection, "session-a");
  const sessionB = new CdpPipeSession(connection, "session-b");

  const resultA = sessionA.send("Runtime.evaluate", { expression: "1 + 1" });
  const resultB = sessionB.send("DOM.getDocument", { depth: 1 });
  const commands = readOutboundMessages(outboundChunks);

  assert.deepEqual(commands, [
    {
      id: 1,
      method: "Runtime.evaluate",
      params: { expression: "1 + 1" },
      sessionId: "session-a",
    },
    {
      id: 2,
      method: "DOM.getDocument",
      params: { depth: 1 },
      sessionId: "session-b",
    },
  ]);

  readable.write(Buffer.from(
    `${JSON.stringify({ id: 2, result: { root: { nodeId: 42 } }, sessionId: "session-b" })}\0`
  ));
  readable.write(Buffer.from(
    `${JSON.stringify({ id: 1, result: { result: { value: 2 } }, sessionId: "session-a" })}\0`
  ));

  assert.deepEqual(await resultA, { result: { value: 2 } });
  assert.deepEqual(await resultB, { root: { nodeId: 42 } });
  connection.close();
});

test("connection forwards browser and flattened-session events unchanged", () => {
  const { readable, transport } = createPipeFixture();
  const connection = new CdpPipeConnection(transport);
  const events = [];
  connection.onEvent((event) => events.push(event));

  const browserEvent = {
    method: "Target.targetCreated",
    params: { targetInfo: { targetId: "target-1" } },
  };
  const sessionEvent = {
    method: "Runtime.consoleAPICalled",
    params: { type: "log" },
    sessionId: "session-a",
  };
  readable.write(Buffer.from(
    `${JSON.stringify(browserEvent)}\0${JSON.stringify(sessionEvent)}\0`
  ));

  assert.deepEqual(events, [browserEvent, sessionEvent]);
  connection.close();
});

test("malformed JSON closes the connection and rejects pending commands", async () => {
  const { readable, transport, writable } = createPipeFixture();
  const connection = new CdpPipeConnection(transport);
  const pending = connection.send("Browser.getVersion");

  readable.write(Buffer.from("{not-json}\0"));

  await assert.rejects(pending, /CDP pipe returned malformed JSON/);
  assert.equal(connection.closed, true);
  assert.equal(transport.closed, true);
  assert.equal(connection.pending.size, 0);
  assert.equal(readable.destroyed, true);
  assert.equal(writable.destroyed, true);
});

test("invalid UTF-8 closes the transport before JSON parsing", () => {
  const { readable, transport, writable } = createPipeFixture();
  let closeError;
  transport.onClose((error) => { closeError = error; });

  readable.write(Buffer.from([0x7b, 0x22, 0x78, 0x22, 0x3a, 0x22, 0x80, 0x22, 0x7d, 0x00]));

  assert.match(closeError?.message ?? "", /invalid UTF-8/);
  assert.equal(transport.closed, true);
  assert.equal(readable.destroyed, true);
  assert.equal(writable.destroyed, true);
});

test("unrecognized JSON messages close the connection", async () => {
  const { readable, transport } = createPipeFixture();
  const connection = new CdpPipeConnection(transport);
  const pending = connection.send("Browser.getVersion");

  readable.write(Buffer.from("{}\0"));

  await assert.rejects(pending, /unrecognized message/);
  assert.equal(connection.closed, true);
});

test("oversized remainder after a valid frame closes the transport", () => {
  const { readable, transport, writable } = createPipeFixture({ maxFrameBytes: 4 });
  const messages = [];
  let closeError;
  transport.onMessage((message) => messages.push(message));
  transport.onClose((error) => { closeError = error; });

  readable.write(Buffer.from("okay\0abcde"));

  assert.deepEqual(messages, ["okay"]);
  assert.match(closeError?.message ?? "", /exceeded the maximum size/);
  assert.equal(transport.closed, true);
  assert.equal(readable.destroyed, true);
  assert.equal(writable.destroyed, true);
});

test("command timeout rejects only the expired command and clears its waiter", async () => {
  const { transport } = createPipeFixture();
  const connection = new CdpPipeConnection(transport, { commandTimeoutMs: 10 });

  await assert.rejects(
    connection.send("Target.getTargets"),
    /CDP command timed out: Target\.getTargets/
  );

  assert.equal(connection.closed, false);
  assert.equal(connection.pending.size, 0);
  connection.close();
});

test("explicit transport close destroys both streams and rejects pending commands", async () => {
  const { readable, transport, writable } = createPipeFixture();
  const connection = new CdpPipeConnection(transport);
  const pending = connection.send("Target.setDiscoverTargets", { discover: true });

  transport.close(new Error("fixture shutdown"));

  await assert.rejects(pending, /fixture shutdown/);
  assert.equal(connection.closed, true);
  assert.equal(connection.pending.size, 0);
  assert.equal(readable.destroyed, true);
  assert.equal(writable.destroyed, true);
});

test("target policy invalidates and detaches an app target that navigates to HTTPS", () => {
  const appTarget = { type: "page", targetId: "target-1", url: "app://codex/" };
  const webTarget = { ...appTarget, url: "https://example.com/" };

  assert.equal(isPotentialCodexTarget(appTarget), true);
  assert.equal(isPotentialCodexTarget(webTarget), false);
  assert.deepEqual(classifyTargetTransition(appTarget, webTarget), {
    sameTarget: true,
    previousProtocol: "app:",
    currentProtocol: "https:",
    invalidate: true,
    detach: true,
  });
  assert.equal(classifyTargetTransition(appTarget, { ...appTarget }).invalidate, false);
});

test("Codex child environment removes case-insensitive Node, Electron, Chromium, TLS, and loader hooks", () => {
  const sanitized = createCodexEnvironment({
    Path: "C:\\Windows\\System32",
    TEMP: "C:\\Temp",
    node_options: "--require attacker.js",
    Electron_Run_As_Node: "1",
    CHROME_USER_DATA_DIR: "C:\\attacker-profile",
    OpenSSL_Conf: "C:\\attacker.cnf",
    SSL_CERT_FILE: "C:\\attacker.pem",
    https_proxy: "http://attacker.invalid",
    LD_PRELOAD: "attacker.dll",
    DYLD_INSERT_LIBRARIES: "attacker.dylib",
  });

  assert.deepEqual(sanitized, {
    Path: "C:\\Windows\\System32",
    TEMP: "C:\\Temp",
  });
});

test("asset hash boundary rejects content that was not explicitly reviewed", () => {
  const expected = {
    "fixture.css": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  };
  assert.doesNotThrow(() => assertAssetHashes({ "fixture.css": Buffer.from("abc") }, expected));
  assert.throws(
    () => assertAssetHashes({ "fixture.css": Buffer.from("modified") }, expected),
    /asset hash mismatch.*Review the asset diff/i,
  );

  const lineEndingExpected = {
    "fixture.js": "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb",
  };
  assert.doesNotThrow(() => assertAssetHashes(
    { "fixture.js": Buffer.from("abc\r\n") },
    lineEndingExpected,
  ));
});
