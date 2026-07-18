const DEFAULT_COMMAND_TIMEOUT_MS = 10000;
const DEFAULT_MAX_FRAME_BYTES = 64 * 1024 * 1024;

export class NulDelimitedPipeTransport {
  constructor(writable, readable, { maxFrameBytes = DEFAULT_MAX_FRAME_BYTES } = {}) {
    if (!writable?.write || !readable?.on) {
      throw new TypeError("Pipe transport requires writable and readable streams");
    }
    if (!Number.isSafeInteger(maxFrameBytes) || maxFrameBytes < 1) {
      throw new TypeError("Pipe transport maximum frame size must be a positive integer");
    }
    this.writable = writable;
    this.readable = readable;
    this.maxFrameBytes = maxFrameBytes;
    this.decoder = new TextDecoder("utf-8", { fatal: true });
    this.pending = Buffer.alloc(0);
    this.closed = false;
    this.messageListeners = new Set();
    this.closeListeners = new Set();

    this.onData = (chunk) => this.dispatch(Buffer.from(chunk));
    this.onReadError = (error) => this.close(error);
    this.onWriteError = (error) => this.close(error);
    this.onStreamClose = () => this.close(new Error("CDP pipe closed"));
    readable.on("data", this.onData);
    readable.on("error", this.onReadError);
    readable.on("close", this.onStreamClose);
    writable.on("error", this.onWriteError);
    writable.on("close", this.onStreamClose);
  }

  onMessage(listener) {
    this.messageListeners.add(listener);
    return () => this.messageListeners.delete(listener);
  }

  onClose(listener) {
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  send(message) {
    if (this.closed) throw new Error("CDP pipe is closed");
    const frame = Buffer.from(`${message}\0`, "utf8");
    if (frame.length - 1 > this.maxFrameBytes) {
      throw new Error("CDP command exceeds the maximum pipe frame size");
    }
    this.writable.write(frame);
  }

  dispatch(chunk) {
    if (this.closed) return;
    this.pending = this.pending.length ? Buffer.concat([this.pending, chunk]) : chunk;
    if (this.pending.length > this.maxFrameBytes && this.pending.indexOf(0) === -1) {
      this.close(new Error("CDP pipe frame exceeded the maximum size"));
      return;
    }

    let delimiter = this.pending.indexOf(0);
    while (delimiter !== -1) {
      if (delimiter > this.maxFrameBytes) {
        this.close(new Error("CDP pipe frame exceeded the maximum size"));
        return;
      }
      let message;
      try {
        message = this.decoder.decode(this.pending.subarray(0, delimiter));
      } catch {
        this.close(new Error("CDP pipe returned invalid UTF-8"));
        return;
      }
      this.pending = this.pending.subarray(delimiter + 1);
      try {
        for (const listener of this.messageListeners) listener(message);
      } catch (error) {
        this.close(error);
        return;
      }
      delimiter = this.pending.indexOf(0);
    }
    if (this.pending.length > this.maxFrameBytes) {
      this.close(new Error("CDP pipe frame exceeded the maximum size"));
    }
  }

  close(error = new Error("CDP pipe closed")) {
    if (this.closed) return;
    this.closed = true;
    this.readable.off("data", this.onData);
    this.readable.off("error", this.onReadError);
    this.readable.off("close", this.onStreamClose);
    this.writable.off("error", this.onWriteError);
    this.writable.off("close", this.onStreamClose);
    this.pending = Buffer.alloc(0);
    try { this.writable.destroy(); } catch {}
    if (this.readable !== this.writable) {
      try { this.readable.destroy(); } catch {}
    }
    for (const listener of this.closeListeners) listener(error);
    this.messageListeners.clear();
    this.closeListeners.clear();
  }
}

export class CdpPipeConnection {
  constructor(transport, { commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS } = {}) {
    this.transport = transport;
    this.commandTimeoutMs = commandTimeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.eventListeners = new Set();
    this.closed = false;
    this.transport.onMessage((message) => this.handleMessage(message));
    this.transport.onClose((error) => this.close(error));
  }

  onEvent(listener) {
    this.eventListeners.add(listener);
    return () => this.eventListeners.delete(listener);
  }

  send(method, params = {}, sessionId = null) {
    if (this.closed) return Promise.reject(new Error("CDP connection is closed"));
    const id = this.nextId++;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, this.commandTimeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      try {
        this.transport.send(JSON.stringify(message));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  handleMessage(rawMessage) {
    let message;
    try {
      message = JSON.parse(rawMessage);
    } catch {
      this.close(new Error("CDP pipe returned malformed JSON"));
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      this.close(new Error("CDP pipe returned an invalid message"));
      return;
    }

    if (Number.isInteger(message.id)) {
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      clearTimeout(waiter.timeout);
      this.pending.delete(message.id);
      if (message.error) {
        waiter.reject(new Error(`${message.error.message ?? "CDP command failed"} (${message.error.code ?? "unknown"})`));
      } else {
        waiter.resolve(message.result ?? {});
      }
      return;
    }

    if (typeof message.method === "string") {
      for (const listener of this.eventListeners) listener(message);
      return;
    }
    this.close(new Error("CDP pipe returned an unrecognized message"));
  }

  close(error = new Error("CDP connection closed")) {
    if (this.closed) return;
    this.closed = true;
    this.transport.close(error);
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    this.pending.clear();
    this.eventListeners.clear();
  }
}

export class CdpPipeSession {
  constructor(connection, sessionId) {
    this.connection = connection;
    this.sessionId = sessionId;
  }

  send(method, params = {}) {
    return this.connection.send(method, params, this.sessionId);
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: false,
    });
    if (result.exceptionDetails) {
      const detail = result.exceptionDetails.exception?.description ?? result.exceptionDetails.text;
      throw new Error(`Renderer evaluation failed: ${detail}`);
    }
    return result.result?.value;
  }
}
