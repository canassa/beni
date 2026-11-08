// The native half of the WebGPU differential harness (docs/design/webgpu.md
// §10): the operation sequence `GpuDiff.beni` generates, run on raw WebGPU —
// whichever host `GpuHost.inject` prepared — on a device of its own, with
// each operation's outcome observed the way a JavaScript program observes
// it: an exception the specification throws, a rejected promise, or an
// error one of the operation's own error scopes caught. Nothing here knows
// beni's rules; the beni half runs the same text through the wrappers and
// the two outcome lists are compared.

// GPUMapMode.READ.
const MAP_READ = 1;

const pattern = (op, length) => {
  const bytes = new globalThis.Uint8Array(length);
  for (let i = 0; i < length; i += 1) bytes[i] = (op * 37 + i * 11 + 5) % 256;
  return bytes;
};

const hex = (bytes) => globalThis.Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

// The exceptions the specification names for these operations, and only
// those: anything else is a fault of the harness or the host and is
// re-thrown.
const expected = (e) =>
  e instanceof globalThis.RangeError ||
  e instanceof globalThis.TypeError ||
  (e instanceof globalThis.DOMException && (e.name === "OperationError" || e.name === "AbortError"));

// Run `body` between a validation and an out-of-memory scope. Its outcome
// is "error" when it threw an expected exception, its promise rejected
// with one, or a scope caught an error, and otherwise the token it gave
// ("ok" when it gave none).
const scoped = (device, body) => {
  device.pushErrorScope("validation");
  device.pushErrorScope("out-of-memory");
  let outcome;
  try {
    outcome = globalThis.Promise.resolve(body()).then(
      (token) => token ?? "ok",
      (e) => {
        if (!expected(e)) throw e;
        return "error";
      },
    );
  } catch (e) {
    if (!expected(e)) throw e;
    outcome = globalThis.Promise.resolve("error");
  }
  const memory = device.popErrorScope();
  const validation = device.popErrorScope();
  return globalThis.Promise.all([outcome, memory, validation]).then(([token, m, v]) => (m !== null || v !== null ? "error" : token));
};

const step = (device, slots, i, text) => {
  const [kind, ...rest] = text.split(" ");
  const n = rest.map(globalThis.Number);
  if (kind === "create") {
    const [k, size, usage, atCreation] = n;
    slots[k] = null;
    // An invalid buffer stays in its slot, as the native API keeps it.
    return scoped(device, () => {
      const buffer = device.createBuffer({ size, usage, mappedAtCreation: atCreation === 1 });
      slots[k] = buffer;
      if (atCreation === 1) {
        new globalThis.Uint8Array(buffer.getMappedRange()).set(pattern(i, size));
        buffer.unmap();
      }
    });
  }
  if (kind === "destroy") {
    slots[n[0]]?.destroy();
    return globalThis.Promise.resolve("ok");
  }
  const buffer = slots[n[0]];
  if (buffer === null) return globalThis.Promise.resolve("error");
  if (kind === "write") return scoped(device, () => device.queue.writeBuffer(buffer, n[1], pattern(i, n[2])));
  if (kind === "copy") {
    const target = slots[n[1]];
    if (target === null) return globalThis.Promise.resolve("error");
    return scoped(device, () => {
      const encoder = device.createCommandEncoder();
      encoder.copyBufferToBuffer(buffer, n[2], target, n[3], n[4]);
      device.queue.submit([encoder.finish()]);
    });
  }
  if (kind === "clear")
    return scoped(device, () => {
      const encoder = device.createCommandEncoder();
      encoder.clearBuffer(buffer, n[1], n[2]);
      device.queue.submit([encoder.finish()]);
    });
  if (kind === "read")
    return scoped(device, () =>
      buffer.mapAsync(MAP_READ).then(() => {
        const bytes = "bytes:" + hex(new globalThis.Uint8Array(buffer.getMappedRange()));
        buffer.unmap();
        return bytes;
      }),
    ).then((token) => {
      buffer.unmap();
      return token;
    });
  if (kind === "map")
    return scoped(device, () => buffer.mapAsync(MAP_READ, n[1], n[2])).then((token) => {
      buffer.unmap();
      return token;
    });
  throw new globalThis.Error(`GpuDiff: no operation "${kind}"`);
};

// Run `text` natively and call `done` with the outcomes, one token per
// operation. A fault of the harness itself is reported as its outcome, so
// the comparison fails and names it.
export const runNative = (text, done) => {
  const ops = text === "" ? [] : text.split(";");
  const slots = [null, null, null, null];
  const out = [];
  let device = null;
  let chain = globalThis.navigator.gpu
    .requestAdapter()
    .then((adapter) => adapter.requestDevice())
    .then((d) => {
      device = d;
    });
  ops.forEach((op, i) => {
    chain = chain.then(() => step(device, slots, i, op)).then((token) => {
      out.push(token);
    });
  });
  chain.then(
    () => {
      device.destroy();
      done(out.join(" "));
    },
    (e) => done(`native harness fault: ${e?.name}: ${e?.message}`),
  );
  return null;
};
