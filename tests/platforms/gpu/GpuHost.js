// The WebGPU fixtures' host (docs/design/webgpu.md §10). `inject` prepares
// it once per page: under `zig build test-webgpu` the driver sets
// `__beniWebGpuNative` and the host is Chrome's own WebGPU; anywhere else
// it is the fake below, which keeps to the IDL's shapes and resolves every
// promise on a microtask, so the gates' happy-dom can run the engine's
// wrapper logic. A fault then wraps the native method it is about, on
// whichever host is there.
//
// The fake is not WebGPU: it validates nothing a fixture does not ask it to.
// Where it differs from Chrome's, on purpose:
// - every promise settles on a microtask, never after GPU work:
//   `onSubmittedWorkDone` resolves at once, a map one microtask after it is
//   asked for (or, under "maps-held", when `releaseMaps` says);
// - a device's loss changes no outcome of its own: a pending map is not
//   rejected by a loss, and work submitted on a lost device still "runs";
// - it runs no shader and keeps no texels, so a dispatch writes nothing
//   and a texture reads back as zeros (those pages have a
//   `.webgpu-expected` for Chrome's answer);
// - its validation is the handful of rules the fixtures reach (buffer
//   usages and sizes, map ranges, writeBuffer bounds, sampler clamps), and
//   its error messages are its own;
// - its error classes (`GPUValidationError` and the rest) are plain
//   functions installed on the page, and `SharedArrayBuffer` exists where
//   a Chrome page without cross-origin isolation has none.

// Where it departs from the specification on purpose:
// - no texel is ever stored: a copy or a render reads back zeros, so a
//   pixel fixture compares in `test-webgpu` only (`.webgpu-expected`);
// - no shader runs, and a pipeline is valid when its entry points exist;
// - a canvas presents its current texture on the next task (`setTimeout`),
//   not at the browser's rendering update, and a presented texture is
//   treated as destroyed by later encodings;
// - every promise settles on a microtask, so frames and batches run in one
//   task unless a fixture waits on a timer;
// - only the validation rules a fixture reaches are modelled.

const native = () => globalThis.__beniWebGpuNative === true;

// ---- The fake host --------------------------------------------------------

const limitDefaults = {
  maxTextureDimension1D: 8192, maxTextureDimension2D: 8192, maxTextureDimension3D: 2048,
  maxTextureArrayLayers: 256, maxBindGroups: 4, maxBindGroupsPlusVertexBuffers: 24,
  maxImmediateSize: 64, maxBindingsPerBindGroup: 1000,
  maxDynamicUniformBuffersPerPipelineLayout: 8, maxDynamicStorageBuffersPerPipelineLayout: 4,
  maxSampledTexturesPerShaderStage: 16, maxSamplersPerShaderStage: 16,
  maxStorageBuffersPerShaderStage: 8, maxStorageBuffersInVertexStage: 8,
  maxStorageBuffersInFragmentStage: 8, maxStorageTexturesPerShaderStage: 4,
  maxStorageTexturesInVertexStage: 4, maxStorageTexturesInFragmentStage: 4,
  maxUniformBuffersPerShaderStage: 12, maxUniformBufferBindingSize: 65536,
  maxStorageBufferBindingSize: 134217728, minUniformBufferOffsetAlignment: 256,
  minStorageBufferOffsetAlignment: 256, maxVertexBuffers: 8, maxBufferSize: 268435456,
  maxVertexAttributes: 16, maxVertexBufferArrayStride: 2048, maxInterStageShaderVariables: 16,
  maxColorAttachments: 8, maxColorAttachmentBytesPerSample: 32,
  maxComputeWorkgroupStorageSize: 16384, maxComputeInvocationsPerWorkgroup: 256,
  maxComputeWorkgroupSizeX: 256, maxComputeWorkgroupSizeY: 256, maxComputeWorkgroupSizeZ: 64,
  maxComputeWorkgroupsPerDimension: 65535,
};

// Features of the fake adapter: names of the pin, and one it does not list.
const adapterFeatures = ["depth-clip-control", "timestamp-query", "x-beni-unlisted"];

const lostInfo = (reason, message) => ({ reason, message });

// GPUBufferUsage and GPUMapMode bits the fake checks.
const MAP_READ = 1;
const MAP_WRITE = 2;
const COPY_SRC = 4;
const COPY_DST = 8;
const operationError = (message) => new globalThis.DOMException(message, "OperationError");
const abortError = (message) => new globalThis.DOMException(message, "AbortError");
// Every fake buffer: its storage and map state.
const fakeBuffers = new globalThis.WeakMap();
// Every fake shader module's source, and every command buffer's commands.
const fakeModules = new globalThis.WeakMap();
const fakeCommands = new globalThis.WeakMap();

// Every render command the page issued, as text, for a fixture to read with
// `GpuHost.commands`: a handle shows its label, a list its length.
const renderLog = [];
const shown = (arg) => {
  if (arg === null) return "null";
  if (arg === undefined) return "undefined";
  if (globalThis.Array.isArray(arg)) return `[${arg.map(shown).join(",")}]`;
  if (typeof arg === "object") return arg.label !== undefined ? `<${arg.label}>` : globalThis.JSON.stringify(arg);
  return globalThis.String(arg);
};
const logged = (name, args) => {
  renderLog.push(`${name}(${args.map(shown).join(", ")})`);
};
// The commands a render pass and a render bundle encoder share; `invalid`
// marks the encoding invalid, as a draw with no pipeline does.
const renderEncoder = (label, invalid) => {
  const e = { label: label ?? "" };
  let pipelineSet = false;
  e.setPipeline = (p) => {
    pipelineSet = true;
    logged("setPipeline", [p]);
  };
  for (const name of ["setBindGroup", "setVertexBuffer", "setIndexBuffer", "pushDebugGroup", "popDebugGroup", "insertDebugMarker"]) e[name] = (...args) => logged(name, args);
  for (const name of ["draw", "drawIndexed", "drawIndirect", "drawIndexedIndirect"])
    e[name] = (...args) => {
      if (!pipelineSet) invalid();
      logged(name, args);
    };
  e.setImmediates = (rangeOffset, data, dataOffset = 0, size = undefined) => {
    const per = data instanceof globalThis.ArrayBuffer || data instanceof globalThis.DataView ? 1 : data.BYTES_PER_ELEMENT;
    const available = data.byteLength / per;
    const contents = size === undefined ? available - dataOffset : size;
    if (dataOffset + contents > available || (contents * per) % 4 !== 0) throw operationError("the immediate data is outside its source");
    logged("setImmediates", [rangeOffset, contents * per]);
  };
  return e;
};

const fakeDevice = (adapter, descriptor) => {
  let resolveLost = null;
  const device = {
    features: new globalThis.Set(descriptor?.requiredFeatures ?? []),
    limits: globalThis.Object.freeze({ ...limitDefaults }),
    adapterInfo: adapter.info,
    queue: { label: "" },
    label: descriptor?.label ?? "",
    lost: new globalThis.Promise((done) => (resolveLost = done)),
  };
  // Every buffer the device made: `destroy` unmaps each, as the
  // specification's device destruction does.
  const buffers = [];
  device.destroy = () => {
    for (const b of buffers) b.unmap();
    resolveLost(lostInfo("destroyed", "the device was destroyed"));
  };
  // The error scopes: a stack of `{ filter, error }`, each keeping the first
  // error of its filter that a call reports.
  const scopes = [];
  device.pushErrorScope = (filter) => {
    scopes.push({ filter, error: null });
  };
  device.popErrorScope = () => {
    const scope = scopes.pop();
    if (scope === undefined) return globalThis.Promise.reject(new globalThis.DOMException("the error scope stack is empty", "OperationError"));
    return globalThis.Promise.resolve(scope.error);
  };
  // The device is an event target of `uncapturederror` only: an error no
  // scope of its filter takes is dispatched there, on a microtask (a
  // browser dispatches it on a task).
  const eventListeners = [];
  device.addEventListener = (type, listener) => {
    if (type === "uncapturederror") eventListeners.push(listener);
  };
  device.dispatchEvent = (event) => {
    if (event.type === "uncapturederror") for (const listener of eventListeners.slice()) listener.call(device, event);
    return true;
  };
  const report = (filter, error) => {
    for (let i = scopes.length - 1; i >= 0; i -= 1) {
      if (scopes[i].filter !== filter) continue;
      if (scopes[i].error === null) scopes[i].error = error;
      return;
    }
    globalThis.queueMicrotask(() => device.dispatchEvent({ type: "uncapturederror", error }));
  };
  deviceReports.set(device, report);
  // Two of the specification's sampler rules, enough for the fixtures.
  device.createSampler = (descriptor) => {
    const d = descriptor ?? {};
    const min = d.lodMinClamp ?? 0;
    const max = d.lodMaxClamp ?? 32;
    const anisotropic = (d.maxAnisotropy ?? 1) > 1;
    const linear = d.magFilter === "linear" && d.minFilter === "linear" && d.mipmapFilter === "linear";
    if (min < 0 || max < min || (anisotropic && !linear)) report("validation", new globalThis.GPUValidationError("invalid sampler descriptor"));
    return { label: d.label ?? "" };
  };
  // Buffers and the queue (docs/design/webgpu.md §7, §8.3): the
  // specification's content-timeline throws and device-timeline validation
  // that the fixtures reach, over plain storage. A buffer's own state is
  // in `fakeBuffers`, never on the object the page holds.
  device.createBuffer = (descriptor) => {
    const size = descriptor.size;
    const usage = descriptor.usage;
    const atCreation = descriptor.mappedAtCreation === true;
    if (atCreation && size % 4 !== 0) throw new globalThis.RangeError("a buffer mapped at creation needs a size that is a multiple of 4");
    let valid = usage !== 0 && (usage & ~1023) === 0 && size <= limitDefaults.maxBufferSize;
    if ((usage & MAP_READ) !== 0 && (usage & ~(MAP_READ | COPY_DST)) !== 0) valid = false;
    if ((usage & MAP_WRITE) !== 0 && (usage & ~(MAP_WRITE | COPY_SRC)) !== 0) valid = false;
    if (!valid) report("validation", new globalThis.GPUValidationError("invalid buffer descriptor"));
    const s = { valid, size, usage, storage: new globalThis.Uint8Array(valid || atCreation ? size : 0), mapState: "unmapped", pending: null, mode: 0, offset: 0, length: 0, ranges: [], destroyed: false };
    const buffer = {
      label: descriptor.label ?? "",
      size,
      usage,
    };
    globalThis.Object.defineProperty(buffer, "mapState", { get: () => s.mapState });
    fakeBuffers.set(buffer, s);
    buffers.push(buffer);
    if (atCreation) {
      s.mapState = "mapped";
      s.mode = MAP_WRITE;
      s.length = size;
    }
    const endMapping = () => {
      for (const r of s.ranges) {
        if (s.mode !== MAP_READ && s.valid) s.storage.set(new globalThis.Uint8Array(r.storage), r.offset);
        r.storage.transfer();
      }
      s.ranges = [];
      s.mapState = "unmapped";
    };
    buffer.mapAsync = (mode, offset = 0, rangeSize = undefined) => {
      if (s.pending !== null) return globalThis.Promise.reject(operationError("a map of the buffer is pending"));
      const length = rangeSize === undefined ? globalThis.Math.max(0, size - offset) : rangeSize;
      const invalid = !s.valid || s.destroyed || s.mapState !== "unmapped" || (mode !== MAP_READ && mode !== MAP_WRITE) || (mode & usage) === 0 || offset % 8 !== 0 || length % 4 !== 0 || offset + length > size;
      if (invalid) {
        report("validation", new globalThis.GPUValidationError("invalid mapAsync"));
        return globalThis.Promise.reject(operationError("mapAsync failed validation"));
      }
      s.mapState = "pending";
      return new globalThis.Promise((resolve, reject) => {
        const pending = { reject };
        s.pending = pending;
        const settle = () => {
          if (s.pending !== pending) return;
          s.pending = null;
          s.mapState = "mapped";
          s.mode = mode;
          s.offset = offset;
          s.length = length;
          resolve(undefined);
        };
        // Under "maps-held" the map stays pending until `releaseMaps`, so an
        // unmap or a destroy meanwhile rejects it with `AbortError`.
        if (holdMaps) heldFakeMaps.push(settle);
        else globalThis.queueMicrotask(settle);
      });
    };
    buffer.getMappedRange = (offset = 0, rangeSize = undefined) => {
      const length = rangeSize === undefined ? globalThis.Math.max(0, size - offset) : rangeSize;
      if (s.mapState !== "mapped") throw operationError("the buffer is not mapped");
      if (offset % 8 !== 0 || length % 4 !== 0 || offset < s.offset || offset + length > s.offset + s.length) throw operationError("the range is outside the mapping");
      if (s.ranges.some((r) => offset < r.offset + r.length && r.offset < offset + length)) throw operationError("the range overlaps another");
      const storage = new globalThis.ArrayBuffer(length);
      new globalThis.Uint8Array(storage).set(s.storage.subarray(offset, offset + length));
      s.ranges.push({ offset, length, storage });
      return storage;
    };
    buffer.unmap = () => {
      if (s.pending !== null) {
        const pending = s.pending;
        s.pending = null;
        s.mapState = "unmapped";
        pending.reject(abortError("the buffer was unmapped while its map was pending"));
      } else if (s.mapState === "mapped") endMapping();
    };
    buffer.destroy = () => {
      buffer.unmap();
      s.destroyed = true;
    };
    return buffer;
  };
  device.queue.writeBuffer = (buffer, bufferOffset, data, dataOffset = 0, size = undefined) => {
    const whole = data instanceof globalThis.ArrayBuffer || (globalThis.SharedArrayBuffer !== undefined && data instanceof globalThis.SharedArrayBuffer);
    const per = whole || data instanceof globalThis.DataView ? 1 : data.BYTES_PER_ELEMENT;
    const dataSize = data.byteLength / per;
    if (dataOffset > dataSize) throw operationError("dataOffset is past the data");
    const contents = size === undefined ? dataSize - dataOffset : size;
    if (dataOffset + contents > dataSize || (contents * per) % 4 !== 0) throw operationError("the data range is outside the data or not a multiple of 4 bytes");
    const bytes = contents * per;
    const s = fakeBuffers.get(buffer);
    if (s === undefined || !s.valid || s.destroyed || s.mapState !== "unmapped" || (s.usage & COPY_DST) === 0 || bufferOffset % 4 !== 0 || bufferOffset + bytes > s.size) {
      report("validation", new globalThis.GPUValidationError("invalid writeBuffer"));
      return;
    }
    const start = (whole ? 0 : data.byteOffset) + dataOffset * per;
    s.storage.set(new globalThis.Uint8Array(whole ? data : data.buffer, start, bytes), bufferOffset);
  };
  // Shaders, pipelines, bind groups, query sets, textures and command
  // encoders (docs/design/webgpu.md §4, §6.2): enough of their shapes and
  // validation for the fixtures. The fake runs no shader: a dispatch
  // encodes nothing, and a fixture that needs the GPU's answer reads it
  // under `test-webgpu`. Copies and clears run when their command buffer
  // is submitted, as on a GPU.
  const plainObject = (label) => ({ label: label ?? "" });
  // WGSL as the fake sees it: any source with a `fn`; an entry point
  // exists when its `fn` does.
  const wgslValid = (code) => /\bfn\b/.test(code);
  const hasEntry = (code, entry) => entry === undefined || new globalThis.RegExp(`\\bfn\\s+${entry}\\b`).test(code);
  device.createShaderModule = (descriptor) => {
    const valid = wgslValid(descriptor.code);
    if (!valid) report("validation", new globalThis.GPUValidationError("invalid WGSL"));
    const module = plainObject(descriptor.label);
    module.getCompilationInfo = () =>
      globalThis.Promise.resolve({ messages: valid ? [] : [{ message: "expected a declaration", type: "error", lineNum: 1, linePos: 1, offset: 0, length: descriptor.code.length }] });
    fakeModules.set(module, descriptor.code);
    return module;
  };
  device.createBindGroupLayout = (descriptor) => plainObject(descriptor.label);
  device.createPipelineLayout = (descriptor) => plainObject(descriptor.label);
  device.createBindGroup = (descriptor) => plainObject(descriptor.label);
  const pipelineValid = (descriptor) => {
    const code = fakeModules.get(descriptor.compute.module);
    return code !== undefined && wgslValid(code) && hasEntry(code, descriptor.compute.entryPoint);
  };
  const pipeline = (descriptor) => {
    const p = plainObject(descriptor.label);
    p.getBindGroupLayout = (index) => {
      if (index >= limitDefaults.maxBindGroups) report("validation", new globalThis.GPUValidationError("no bind group at that index"));
      return plainObject("");
    };
    return p;
  };
  device.createComputePipeline = (descriptor) => {
    if (!pipelineValid(descriptor)) report("validation", new globalThis.GPUValidationError("invalid compute pipeline"));
    return pipeline(descriptor);
  };
  device.createComputePipelineAsync = (descriptor) =>
    pipelineValid(descriptor)
      ? globalThis.Promise.resolve(pipeline(descriptor))
      : globalThis.Promise.reject(new globalThis.GPUPipelineError("invalid compute pipeline", { reason: "validation" }));
  device.createQuerySet = (descriptor) => {
    if (descriptor.type === "timestamp" && !device.features.has("timestamp-query")) throw new globalThis.TypeError("timestamp-query is not enabled");
    const q = plainObject(descriptor.label);
    q.type = descriptor.type;
    q.count = descriptor.count;
    q.destroy = () => {};
    return q;
  };
  device.createTexture = (descriptor) => {
    const size = descriptor.size;
    const t = plainObject(descriptor.label);
    t.width = size.width ?? size[0];
    t.height = size.height ?? size[1] ?? 1;
    t.depthOrArrayLayers = size.depthOrArrayLayers ?? size[2] ?? 1;
    t.mipLevelCount = descriptor.mipLevelCount ?? 1;
    t.sampleCount = descriptor.sampleCount ?? 1;
    t.dimension = descriptor.dimension ?? "2d";
    t.format = descriptor.format;
    t.usage = descriptor.usage;
    t.destroy = () => {};
    t.createView = (viewDescriptor) => {
      const d = viewDescriptor ?? {};
      if ((d.baseMipLevel ?? 0) + (d.mipLevelCount ?? 1) > t.mipLevelCount) report("validation", new globalThis.GPUValidationError("invalid texture view"));
      const view = plainObject(d.label);
      fakeViewTexture.set(view, t);
      return view;
    };
    return t;
  };
  device.createCommandEncoder = (descriptor) => {
    const commands = [];
    let invalid = false;
    const encoder = plainObject(descriptor?.label);
    encoder.copyBufferToBuffer = (...args) => {
      const [source, sourceOffset, destination, destinationOffset, size] = args.length >= 4 ? args : [args[0], 0, args[1], 0, args[2]];
      const from = fakeBuffers.get(source);
      const length = size === undefined ? from.size - sourceOffset : size;
      if (length % 4 !== 0 || sourceOffset % 4 !== 0 || destinationOffset % 4 !== 0) invalid = true;
      commands.push(() => fakeBuffers.get(destination).storage.set(from.storage.subarray(sourceOffset, sourceOffset + length), destinationOffset));
    };
    encoder.clearBuffer = (buffer, offset = 0, size = undefined) => {
      const s = fakeBuffers.get(buffer);
      const length = size === undefined ? s.size - offset : size;
      if (length % 4 !== 0 || offset % 4 !== 0) invalid = true;
      commands.push(() => s.storage.fill(0, offset, offset + length));
    };
    encoder.resolveQuerySet = (querySet, first, count, destination, offset) => {
      if (offset % 256 !== 0) invalid = true;
      commands.push(() => fakeBuffers.get(destination).storage.fill(0, offset, offset + count * 8));
    };
    encoder.copyBufferToTexture = (_source, destination) => {
      if (fakeStale(destination.texture)) invalid = true;
    };
    encoder.copyTextureToBuffer = (source) => {
      if (fakeStale(source.texture)) invalid = true;
    };
    encoder.copyTextureToTexture = (source, destination) => {
      if (fakeStale(source.texture) || fakeStale(destination.texture)) invalid = true;
    };
    encoder.pushDebugGroup = () => {};
    encoder.popDebugGroup = () => {};
    encoder.insertDebugMarker = () => {};
    encoder.beginComputePass = (passDescriptor) => {
      const pass = plainObject(passDescriptor?.label);
      for (const name of ["setPipeline", "setBindGroup", "dispatchWorkgroups", "dispatchWorkgroupsIndirect", "pushDebugGroup", "popDebugGroup", "insertDebugMarker", "end"]) pass[name] = () => {};
      pass.setImmediates = (rangeOffset, data, dataOffset = 0, size = undefined) => {
        const per = data instanceof globalThis.ArrayBuffer || data instanceof globalThis.DataView ? 1 : data.BYTES_PER_ELEMENT;
        const available = data.byteLength / per;
        const contents = size === undefined ? available - dataOffset : size;
        if (dataOffset + contents > available || (contents * per) % 4 !== 0) throw operationError("the immediate data is outside its source");
        if (rangeOffset + contents * per > limitDefaults.maxImmediateSize) invalid = true;
      };
      return pass;
    };
    encoder.beginRenderPass = (passDescriptor) => {
      for (const a of passDescriptor.colorAttachments ?? []) if (a !== null && (fakeStale(a.view) || fakeStale(a.resolveTarget))) invalid = true;
      const pass = renderEncoder(passDescriptor?.label, () => {
        invalid = true;
      });
      pass.end = () => logged("end", []);
      for (const name of ["setViewport", "setScissorRect", "setBlendConstant", "setStencilReference", "beginOcclusionQuery", "endOcclusionQuery"]) pass[name] = (...args) => logged(name, args);
      pass.executeBundles = (bundles) => logged("executeBundles", [bundles.length]);
      return pass;
    };
    encoder.finish = (finishDescriptor) => {
      if (invalid) report("validation", new globalThis.GPUValidationError("invalid encoder"));
      const buffer = plainObject(finishDescriptor?.label);
      fakeCommands.set(buffer, commands);
      return buffer;
    };
    return encoder;
  };
  // Render pipelines and render bundles (docs/design/webgpu.md §6.2):
  // their shapes, and a draw with no pipeline set, which the device
  // reports at `finish`. The fake rasterises nothing.
  const stageValid = (stage) => {
    const code = fakeModules.get(stage.module);
    return code !== undefined && wgslValid(code) && hasEntry(code, stage.entryPoint);
  };
  const renderValid = (descriptor) => stageValid(descriptor.vertex) && (descriptor.fragment === undefined || stageValid(descriptor.fragment));
  device.createRenderPipeline = (descriptor) => {
    if (!renderValid(descriptor)) report("validation", new globalThis.GPUValidationError("invalid render pipeline"));
    return pipeline(descriptor);
  };
  device.createRenderPipelineAsync = (descriptor) =>
    renderValid(descriptor)
      ? globalThis.Promise.resolve(pipeline(descriptor))
      : globalThis.Promise.reject(new globalThis.GPUPipelineError("invalid render pipeline", { reason: "validation" }));
  device.createRenderBundleEncoder = (descriptor) => {
    let invalid = false;
    const encoder = renderEncoder(descriptor.label, () => {
      invalid = true;
    });
    encoder.finish = (finishDescriptor) => {
      if (invalid) report("validation", new globalThis.GPUValidationError("invalid render bundle"));
      return plainObject(finishDescriptor?.label);
    };
    return encoder;
  };
  device.queue.submit = (commandBuffers) => {
    for (const b of commandBuffers) for (const run of fakeCommands.get(b) ?? []) run();
  };
  device.queue.writeTexture = () => {};
  // External images (docs/design/webgpu.md §8; ledger §6): the content-timeline
  // checks of the specification — a source another origin tainted, a copy
  // outside the source, a closed frame — and the destination's usage and
  // the copy's depth, reported to the device. No texel is copied.
  device.queue.copyExternalImageToTexture = (source, destination, copySize) => {
    const image = source.source;
    if (taintedMedia.has(image)) throw new globalThis.DOMException("the source is not origin-clean", "SecurityError");
    const size = mediaSize(image);
    const origin = source.origin ?? {};
    const x = origin.x ?? origin[0] ?? 0;
    const y = origin.y ?? origin[1] ?? 0;
    const width = copySize.width ?? copySize[0];
    const height = copySize.height ?? copySize[1] ?? 1;
    const layers = copySize.depthOrArrayLayers ?? copySize[2] ?? 1;
    if (x + width > size.width || y + height > size.height || layers > 1) throw operationError("the copy is outside the source");
    if (closedMedia(image)) throw new globalThis.DOMException("the source is closed", "InvalidStateError");
    const usage = destination.texture.usage;
    if ((usage & TEXTURE_RENDER_ATTACHMENT) === 0 || (usage & TEXTURE_COPY_DST) === 0) report("validation", new globalThis.GPUValidationError("the destination needs RENDER_ATTACHMENT and COPY_DST"));
  };
  device.importExternalTexture = (descriptor) => {
    const source = descriptor.source;
    if (taintedMedia.has(source)) throw new globalThis.DOMException("the source is not origin-clean", "SecurityError");
    if (closedMedia(source)) throw new globalThis.DOMException("the frame is closed", "InvalidStateError");
    return plainObject(descriptor.label);
  };
  device.queue.onSubmittedWorkDone = () => globalThis.Promise.resolve(undefined);
  return device;
};

// ---- Canvas contexts (docs/design/webgpu.md §8; ledger §6) ----------------
//
// Where the page has no WebGPU canvas (happy-dom), a fake `webgpu` context:
// the three canvas formats, a transient usage refused with a `TypeError`,
// a view format of another format family reported to the device, an
// unconfigured `getCurrentTexture` refused with `InvalidStateError`, and one
// current texture per task and canvas size, made by the device. Where the
// page has no `OffscreenCanvas`, a fake one with the same context.
const canvasFormats = ["bgra8unorm", "rgba8unorm", "rgba16float"];
const fakeContexts = new globalThis.WeakMap();
// Canvas textures the fake has presented, and the texture each fake view
// views: an encoding that names one is invalid at `finish`, as a destroyed
// texture is on a GPU.
const fakeExpired = new globalThis.WeakSet();
const fakeViewTexture = new globalThis.WeakMap();
const fakeStale = (object) => object !== undefined && object !== null && (fakeExpired.has(object) || fakeExpired.has(fakeViewTexture.get(object)));
// Every write of a canvas's width or height, by canvas: a write that
// changes nothing counts too, as the specification replaces the drawing
// buffer on every set.
const sizeWrites = new globalThis.WeakMap();
const countSizeWrites = (canvas) => {
  if (sizeWrites.has(canvas)) return;
  sizeWrites.set(canvas, 0);
  for (const name of ["width", "height"]) {
    let owner = canvas;
    let descriptor;
    while (owner !== null && (descriptor = globalThis.Object.getOwnPropertyDescriptor(owner, name)) === undefined) owner = globalThis.Object.getPrototypeOf(owner);
    let value = canvas[name];
    const get = descriptor?.get ? () => descriptor.get.call(canvas) : () => value;
    const set = descriptor?.set ? (v) => descriptor.set.call(canvas, v) : (v) => (value = v);
    globalThis.Object.defineProperty(canvas, name, {
      configurable: true,
      get,
      set: (v) => {
        sizeWrites.set(canvas, sizeWrites.get(canvas) + 1);
        set(v);
      },
    });
  }
};
const fakeContext = (canvas) => {
  let config = null;
  let current = null;
  let currentSize = -1;
  countSizeWrites(canvas);
  const context = { canvas };
  context.configure = (c) => {
    if (!canvasFormats.includes(c.format)) throw new globalThis.TypeError(`${c.format} is not a canvas format`);
    if (((c.usage ?? 16) & 32) !== 0) throw new globalThis.TypeError("a canvas texture cannot be transient");
    const views = c.viewFormats ?? [];
    if (views.some((f) => f.replace("-srgb", "") !== c.format.replace("-srgb", ""))) reportOn(c.device, "invalid view format");
    config = { device: c.device, format: c.format, usage: c.usage ?? 16, viewFormats: [...views], colorSpace: c.colorSpace ?? "srgb", toneMapping: { mode: c.toneMapping?.mode ?? "standard" }, alphaMode: c.alphaMode ?? "opaque" };
    current = null;
  };
  context.unconfigure = () => {
    config = null;
    current = null;
  };
  context.getConfiguration = () => (config === null ? null : { ...config, viewFormats: [...config.viewFormats], toneMapping: { ...config.toneMapping } });
  context.getCurrentTexture = () => {
    if (config === null) throw new globalThis.DOMException("the context is not configured", "InvalidStateError");
    const size = sizeWrites.get(canvas);
    if (current === null || currentSize !== size) {
      if (current !== null) fakeExpired.add(current);
      current = config.device.createTexture({ size: [canvas.width, canvas.height], format: config.format, usage: config.usage });
      currentSize = size;
      const presented = current;
      globalThis.setTimeout(() => {
        fakeExpired.add(presented);
        if (current === presented) current = null;
      }, 0);
    }
    return current;
  };
  return context;
};
// The kind of context each canvas has: a canvas keeps the first kind it
// gave, and a request for another kind is null, as HTML specifies.
const contextKinds = new globalThis.WeakMap();
const contextOfKind = (canvas, kind, make) => {
  const had = contextKinds.get(canvas);
  if (had !== undefined && had !== kind) return null;
  const context = make();
  if (context !== null && context !== undefined) contextKinds.set(canvas, kind);
  return context ?? null;
};
const bitmapContexts = new globalThis.WeakMap();
const bitmapContext = (canvas) => {
  let context = bitmapContexts.get(canvas);
  if (context === undefined) {
    context = { canvas, transferFromImageBitmap: () => undefined };
    bitmapContexts.set(canvas, context);
  }
  return context;
};
const webgpuContext = (canvas) => {
  let context = fakeContexts.get(canvas);
  if (context === undefined) {
    context = fakeContext(canvas);
    fakeContexts.set(canvas, context);
  }
  return context;
};
let canvasesFaked = false;
const fakeCanvases = () => {
  if (canvasesFaked) return;
  canvasesFaked = true;
  const element = globalThis.HTMLCanvasElement;
  if (element !== undefined) {
    const getContext = element.prototype.getContext;
    element.prototype.getContext = function (kind, ...rest) {
      if (kind === "webgpu") return contextOfKind(this, kind, () => webgpuContext(this));
      if (kind === "bitmaprenderer") return contextOfKind(this, kind, () => bitmapContext(this));
      return contextOfKind(this, kind, () => (getContext === undefined ? null : getContext.call(this, kind, ...rest)));
    };
  }
  // happy-dom's own OffscreenCanvas, where it has one, gives no `webgpu` context.
  globalThis.OffscreenCanvas = FakeOffscreenCanvas;
};
function FakeOffscreenCanvas(width, height) {
  this.width = width;
  this.height = height;
}
FakeOffscreenCanvas.prototype.getContext = function (kind) {
  if (kind === "webgpu") return contextOfKind(this, kind, () => webgpuContext(this));
  if (kind === "bitmaprenderer") return contextOfKind(this, kind, () => bitmapContext(this));
  return null;
};
// A validation error a fake device reports into its innermost scope.
const deviceReports = new globalThis.WeakMap();
const reportOn = (device, message) => {
  const report = deviceReports.get(device);
  if (report !== undefined) report("validation", new globalThis.GPUValidationError(message));
};

// The three error classes of a scope, where the host has none (the fake's).
function FakeValidationError(message) {
  this.message = message;
}
function FakeOutOfMemoryError(message) {
  this.message = message;
}
function FakeInternalError(message) {
  this.message = message;
}
function FakePipelineError(message, options) {
  this.message = message;
  this.reason = options.reason;
}
// Printed as a browser prints its own.
FakePipelineError.prototype.toString = function () {
  return `GPUPipelineError: ${this.message}`;
};

const fakeAdapter = () => {
  const adapter = {
    features: new globalThis.Set(moreFeatures ? [...adapterFeatures, "depth32float-stencil8"] : adapterFeatures),
    limits: globalThis.Object.freeze({ ...limitDefaults }),
    info: globalThis.Object.freeze({ vendor: "beni", architecture: "fake", device: "", description: "", subgroupMinSize: 4, subgroupMaxSize: 128, isFallbackAdapter: false }),
  };
  adapter.requestDevice = (descriptor) => globalThis.Promise.resolve(fakeDevice(adapter, descriptor));
  return adapter;
};

const fakeGpu = () => ({
  requestAdapter: (_options) => globalThis.Promise.resolve(fakeAdapter()),
  getPreferredCanvasFormat: () => "bgra8unorm",
  wgslLanguageFeatures: new globalThis.Set(["readonly_and_readwrite_storage_textures", "packed_4x8_integer_dot_product"]),
});

// ---- Faults ---------------------------------------------------------------

// Every answer the host was asked for, for `later` to wait on: requests,
// pops, and the loss of a device the page destroyed.
const hostAnswers = [];
const asked = (promise) => {
  hostAnswers.push(promise);
  return promise;
};

// Requests held since "requests-held", newest last: the host is not asked
// until `releaseRequest` says how the request settles, so a refusal
// injected there is the only answer it gets, on either host.
let holdRequests = false;
const heldRequests = [];
const holding = (call) => {
  if (!holdRequests) return asked(call());
  return new globalThis.Promise((resolve, reject) => heldRequests.push({ call, resolve, reject }));
};

// The devices whose `lost` the fixture settles, whose loss nobody waits for
// in `later`.
const controlledDevices = new globalThis.WeakSet();

// Every device made since "lost-controlled", newest last, with what
// settles its injected `lost`.
const controlled = [];
let controlLoss = false;

// The scope faults of the scenario: per filter, what a pop of that filter
// gives in place of the host's answer (the host's pop is made all the
// same, so its stack stays balanced); whether pops are held until
// `releasePops`; whether `createSampler` throws. And how many times each
// native method of a device was called.
let popFaults = {};
let holdPops = false;
let pushThrowsAt = 0;
let createThrows = false;
let moreFeatures = false;
// The buffer and queue faults of the scenario, by the native call they
// replace; whether map outcomes are held until `releaseMaps`.
let bufferFaults = {};
let holdMaps = false;
const heldMaps = [];
// The fake host's own pending maps, held under "maps-held".
const heldFakeMaps = [];
const held = [];
const callCounts = {};

// Wrap `method` of `object` with `wrap(original, ...args)`.
const wrap = (object, method, wrapper) => {
  const original = object[method];
  object[method] = function (...args) {
    return wrapper.call(this, original, ...args);
  };
};

// A fault on the device request of every adapter `requestAdapter` gives:
// the first request of each meets it, and any later one is the host's.
const onAdapters = (gpu, fault, once = true) =>
  wrap(gpu, "requestAdapter", function (original, ...args) {
    return original.apply(this, args).then((adapter) => {
      if (adapter !== null) {
        let met = false;
        wrap(adapter, "requestDevice", function (request, ...rest) {
          if (met) return request.apply(this, rest);
          met = once;
          return fault.call(this, request, ...rest);
        });
      }
      return adapter;
    });
  });

const faults = {
  none: () => {},
  // Shaders, pipelines and passes (ledger §3, §5): an asynchronous
  // pipeline rejected with what is not a `GPUPipelineError`, compilation
  // messages rejected, and immediate data the host refuses after the
  // engine's checks passed.
  // A pipeline the host refuses for an internal reason, and a
  // GPUPipelineError of a reason outside the pin.
  "pipeline-internal": () => {
    bufferFaults.pipeline = () => globalThis.Promise.reject(new globalThis.GPUPipelineError("injected internal failure", { reason: "internal" }));
  },
  "pipeline-unknown-reason": () => {
    bufferFaults.pipeline = () => {
      // A genuine GPUPipelineError, its reason shadowed by one outside the pin.
      const error = new globalThis.GPUPipelineError("injected unknown reason", { reason: "internal" });
      globalThis.Object.defineProperty(error, "reason", { value: "exploded" });
      return globalThis.Promise.reject(error);
    };
  },
  // A host without setImmediates on its compute passes.
  "immediates-missing": () => {
    bufferFaults.noImmediates = true;
  },
  // The adapter offers BC compression (the fake's own adapter only), and
  // the native format check of createTexture refuses it anyway.
  "adapter-bc": (gpu) => {
    if (native()) return;
    wrap(gpu, "requestAdapter", function (original, ...args) {
      return original.apply(this, args).then((adapter) => {
        if (adapter !== null) adapter.features.add("texture-compression-bc");
        return adapter;
      });
    });
  },
  "texture-type-error": () => {
    bufferFaults.texture = () => {
      throw new globalThis.TypeError("injected format refusal");
    };
  },
  "pipeline-unlisted": () => {
    bufferFaults.pipeline = () => globalThis.Promise.reject(new globalThis.DOMException("injected unlisted pipeline failure", "AbortError"));
  },
  "compilation-rejected": () => {
    bufferFaults.compilation = () => globalThis.Promise.reject(new globalThis.DOMException("injected compilation failure", "AbortError"));
  },
  // Rendering (ledger §3, §5): the content timeline's `TypeError` of a format check
  // after the engine's own passed, an asynchronous render pipeline refused
  // as `internal` or with what is not a `GPUPipelineError`, and passes and
  // bundle encoders without `setImmediates`.
  "view-type-error": () => {
    bufferFaults.view = () => {
      throw new globalThis.TypeError("injected view format refusal");
    };
  },
  "render-type-error": () => {
    bufferFaults.render = () => {
      throw new globalThis.TypeError("injected render format refusal");
    };
  },
  "bundle-type-error": () => {
    bufferFaults.bundle = () => {
      throw new globalThis.TypeError("injected bundle format refusal");
    };
  },
  "render-pipeline-internal": () => {
    bufferFaults.renderAsync = () => globalThis.Promise.reject(new globalThis.GPUPipelineError("injected internal failure", { reason: "internal" }));
  },
  "render-pipeline-unlisted": () => {
    bufferFaults.renderAsync = () => globalThis.Promise.reject(new globalThis.DOMException("injected unlisted render pipeline failure", "AbortError"));
  },
  "render-pipeline-type-error": () => {
    bufferFaults.renderAsync = () => globalThis.Promise.reject(new globalThis.TypeError("injected render format refusal"));
  },
  "no-immediates": () => {
    bufferFaults.noImmediates = true;
  },
  // The adapter also offers `depth32float-stencil8` (the fake's only; a
  // native adapter offers what it has).
  // Canvas surfaces (ledger §6): no `webgpu` context, a configuration the host
  // refuses with a `TypeError` after the engine's checks, and a current
  // texture refused with what the ledger does not list.
  "context-null": () => {
    contextNull = true;
  },
  "configure-range": () => {
    bufferFaults.configure = () => {
      throw new globalThis.RangeError("injected unlisted configuration failure");
    };
  },
  "configure-spoofed": () => {
    bufferFaults.configure = () => {
      throw { name: "TypeError", message: "a plain object named TypeError" };
    };
  },
  "current-spoofed": () => {
    bufferFaults.current = () => {
      throw { name: "InvalidStateError", message: "a plain object named InvalidStateError" };
    };
  },
  "configure-type-error": () => {
    bufferFaults.configure = () => {
      throw new globalThis.TypeError("injected configuration refusal");
    };
  },
  "current-unlisted": () => {
    bufferFaults.current = () => {
      throw new globalThis.TypeError("injected unlisted current texture failure");
    };
  },
  "more-features": () => {
    moreFeatures = true;
  },
  "immediates-rejected": () => {
    bufferFaults.immediates = () => {
      throw new globalThis.DOMException("injected immediate refusal", "OperationError");
    };
  },
  // Spoofed failures (ledger §1, §7): a plain object named like the error
  // each buffer classifier documents is not that error, and an
  // unexpected class at mapped creation is not the allocation failure.
  "map-spoofed-abort": () => {
    bufferFaults.map = () => globalThis.Promise.reject({ name: "AbortError", message: "a plain object, not a DOMException" });
  },
  "map-spoofed-operation": () => {
    bufferFaults.map = () => globalThis.Promise.reject({ name: "OperationError", message: "a plain object, not a DOMException" });
  },
  "map-spoofed-range": () => {
    bufferFaults.map = () => globalThis.Promise.reject({ name: "RangeError", message: "a plain object, not a RangeError" });
  },
  "range-spoofed": () => {
    bufferFaults.range = () => {
      throw { name: "OperationError", message: "a plain object, not a DOMException" };
    };
  },
  "write-spoofed": () => {
    bufferFaults.write = () => {
      throw { name: "OperationError", message: "a plain object, not a DOMException" };
    };
  },
  "buffer-allocation-spoofed": () => {
    bufferFaults.createMapped = () => {
      throw { name: "RangeError", message: "a plain object, not a RangeError" };
    };
  },
  "buffer-allocation-unlisted": () => {
    bufferFaults.createMapped = () => {
      throw new globalThis.TypeError("injected unlisted creation failure");
    };
  },
  // Buffers and the queue (docs/design/webgpu.md §7, §8.3; ledger §3–§5).
  // The CPU memory of a buffer mapped at creation runs out.
  "buffer-allocation-fails": () => {
    bufferFaults.createMapped = () => {
      throw new globalThis.RangeError("injected mapped allocation failure");
    };
  },
  // A map the ledger documents as refused for its CPU memory, one it does
  // not document, and one that fails the device's validation: the request
  // asks the host for a range past the buffer's end, so both the scope
  // and the promise report it.
  "map-allocation-fails": () => {
    bufferFaults.map = () => globalThis.Promise.reject(new globalThis.RangeError("injected map allocation failure"));
  },
  "map-unlisted": () => {
    bufferFaults.map = () => globalThis.Promise.reject(new globalThis.DOMException("injected unlisted map refusal", "NotSupportedError"));
  },
  "map-invalid": () => {
    bufferFaults.map = function (original, mode) {
      return original.call(this, mode, this.size + 8);
    };
  },
  // Every map's outcome waits, after the host's, until `releaseMaps`.
  "maps-held": () => {
    holdMaps = true;
  },
  // The range a host refuses after the engine's checks passed, and a
  // throw the ledger does not list for it.
  "range-rejected": () => {
    bufferFaults.range = () => {
      throw new globalThis.DOMException("injected range refusal", "OperationError");
    };
  },
  "range-unlisted": () => {
    bufferFaults.range = () => {
      throw new globalThis.TypeError("injected unlisted range failure");
    };
  },
  // `writeBuffer` refuses its source as documented, or throws what the
  // ledger does not list.
  "write-rejected": () => {
    bufferFaults.write = () => {
      throw new globalThis.DOMException("injected write refusal", "OperationError");
    };
  },
  // External images (ledger §6): each host failure of the two calls, where
  // Chrome cannot be made to give it on demand, and what the ledger does
  // not list.
  "copy-unusable": () => {
    bufferFaults.copyExternal = () => {
      throw new globalThis.DOMException("injected unusable source", "InvalidStateError");
    };
  },
  "copy-tainted": () => {
    bufferFaults.copyExternal = () => {
      throw new globalThis.DOMException("injected tainted source", "SecurityError");
    };
  },
  "copy-unlisted": () => {
    bufferFaults.copyExternal = () => {
      throw new globalThis.TypeError("injected unlisted copy failure");
    };
  },
  "copy-spoofed": () => {
    bufferFaults.copyExternal = () => {
      throw { name: "SecurityError", message: "a plain object, not a DOMException" };
    };
  },
  "import-tainted": () => {
    bufferFaults.importExternal = () => {
      throw new globalThis.DOMException("injected tainted source", "SecurityError");
    };
  },
  "import-unusable": () => {
    bufferFaults.importExternal = () => {
      throw new globalThis.DOMException("injected unusable source", "InvalidStateError");
    };
  },
  "import-unlisted": () => {
    bufferFaults.importExternal = () => {
      throw new globalThis.DOMException("injected unlisted import failure", "OperationError");
    };
  },
  "import-spoofed": () => {
    bufferFaults.importExternal = () => {
      throw { name: "InvalidStateError", message: "a plain object, not a DOMException" };
    };
  },
  "write-unlisted": () => {
    bufferFaults.write = () => {
      throw new globalThis.TypeError("injected unlisted write failure");
    };
  },
  // The queue's completion promise rejects, which the ledger does not
  // document.
  "work-done-rejected": () => {
    bufferFaults.workDone = () => globalThis.Promise.reject(new globalThis.DOMException("injected completion failure", "AbortError"));
  },
  "no-api": () => globalThis.Object.defineProperty(globalThis.navigator, "gpu", { configurable: true, value: undefined }),
  insecure: () => globalThis.Object.defineProperty(globalThis, "isSecureContext", { configurable: true, value: false }),
  "adapter-null": (gpu) => wrap(gpu, "requestAdapter", () => globalThis.Promise.resolve(null)),
  // A rejection the ledger does not list for `requestAdapter`.
  "adapter-rejected": (gpu) => wrap(gpu, "requestAdapter", () => globalThis.Promise.reject(new globalThis.DOMException("injected adapter refusal", "AbortError"))),
  // The two documented device refusals, and three undocumented ones.
  "device-type-error": (gpu) => onAdapters(gpu, () => globalThis.Promise.reject(new globalThis.TypeError("injected feature refusal"))),
  "device-operation-error": (gpu) => onAdapters(gpu, () => globalThis.Promise.reject(new globalThis.DOMException("injected device refusal", "OperationError"))),
  "device-spoofed": (gpu) => onAdapters(gpu, () => globalThis.Promise.reject({ name: "OperationError", message: "a plain object, not a DOMException" })),
  "device-unlisted": (gpu) => onAdapters(gpu, () => globalThis.Promise.reject(new globalThis.DOMException("injected unlisted refusal", "NotSupportedError"))),
  // The device arrives already lost.
  "device-lost-at-birth": (gpu) =>
    onAdapters(gpu, function (original, ...args) {
      return original.apply(this, args).then((device) => {
        globalThis.Object.defineProperty(device, "lost", { configurable: true, value: globalThis.Promise.resolve(lostInfo("unknown", "injected loss at birth")) });
        return device;
      });
    }),
  // The next device's loss is the fixture's to settle, with `lose`.
  "lost-controlled": () => {
    controlLoss = true;
  },
  "pop-oom": () => {
    popFaults["out-of-memory"] = () => new globalThis.GPUOutOfMemoryError("injected out of memory");
  },
  "pop-internal": () => {
    popFaults.internal = () => new globalThis.GPUInternalError("injected internal error");
  },
  // A pop of the engine's own scopes that rejects: the ledger documents
  // none, so it is a defect.
  "pop-rejected": () => {
    popFaults.internal = () => globalThis.Promise.reject(new globalThis.DOMException("injected pop failure", "OperationError"));
  },
  // A validation scope that reports a plain object named like the error.
  "pop-spoofed": () => {
    popFaults.validation = () => ({ name: "GPUValidationError", message: "a plain object, not a GPUValidationError" });
  },
  "pops-held": () => {
    holdPops = true;
  },
  // A device's second push throws (a diagnostic session's own scopes), or
  // its fourth (the first scope a session pushes for its user).
  "push-throws-open": () => {
    pushThrowsAt = 2;
  },
  "push-throws-user": () => {
    pushThrowsAt = 4;
  },
  "create-throws": () => {
    createThrows = true;
  },
  // The device's `lost` settles with null, or the device has none: what the
  // engine reads of it throws, and that is a defect, never an unhandled
  // rejection.
  "device-null-lost-info": (gpu) =>
    onAdapters(gpu, function (original, ...args) {
      return original.apply(this, args).then((device) => {
        globalThis.Object.defineProperty(device, "lost", { configurable: true, value: globalThis.Promise.resolve(null) });
        return device;
      });
    }),
  "device-without-lost": (gpu) =>
    onAdapters(gpu, function (original, ...args) {
      return original.apply(this, args).then((device) => {
        globalThis.Object.defineProperty(device, "lost", { configurable: true, value: undefined });
        return device;
      });
    }),
  // Every later `requestAdapter` and `requestDevice` waits, after the host
  // answered, until `releaseRequest` settles it.
  "requests-held": () => {
    holdRequests = true;
  },
  // An adapter whose `maxBindGroups` is NaN: a snapshot read refuses it.
  "limits-nan": (gpu) =>
    wrap(gpu, "requestAdapter", function (original, ...args) {
      return original.apply(this, args).then((adapter) => {
        if (adapter === null) return adapter;
        const limits = {};
        for (const name in adapter.limits) limits[name] = adapter.limits[name];
        limits.maxBindGroups = globalThis.Number.NaN;
        globalThis.Object.defineProperty(adapter, "limits", { configurable: true, value: limits });
        return adapter;
      });
    }),
};

// What a hostile host throws where the ledger documents a `TypeError` of a
// format check (ledger §7): a plain object named like one, an `Error` named
// like one, and two native classes the ledger does not list there. Each is
// a defect, never `FormatFeatureRejected`.
const hostile = {
  plain: () => ({ name: "TypeError", message: "a plain object named TypeError" }),
  named: () => globalThis.Object.assign(new globalThis.Error("an Error named TypeError"), { name: "TypeError" }),
  range: () => new globalThis.RangeError("injected RangeError"),
  dom: () => new globalThis.DOMException("injected DOMException", "OperationError"),
};
for (const site of ["view", "render", "bundle"])
  for (const kind of globalThis.Object.keys(hostile))
    faults[`${site}-throws-${kind}`] = () => {
      bufferFaults[site] = () => {
        throw hostile[kind]();
      };
    };
faults["render-pipeline-range"] = () => {
  bufferFaults.renderAsync = () => globalThis.Promise.reject(new globalThis.RangeError("injected RangeError"));
};

// Every device: its scope stack as the page pushed it, so a pop knows its
// filter; its pops, held or faulted; its `createSampler`, counted or made
// to throw.
const instrument = (device) => {
  const stack = [];
  scopeStacks.set(device, stack);
  const count = (name) => {
    callCounts[name] = (callCounts[name] ?? 0) + 1;
  };
  // Every buffer the device makes: its map, its ranges.
  wrap(device, "createBuffer", function (original, descriptor) {
    count("createBuffer");
    if (descriptor?.mappedAtCreation === true && bufferFaults.createMapped !== undefined) return bufferFaults.createMapped();
    const buffer = original.call(this, descriptor);
    wrap(buffer, "mapAsync", function (map, ...args) {
      count("mapAsync");
      const fault = bufferFaults.map;
      const outcome = asked(fault === undefined ? map.apply(this, args) : fault.call(this, map, ...args));
      if (!holdMaps) return outcome;
      // Held, a rejection is handled here until it is released.
      outcome.then(null, () => null);
      return new globalThis.Promise((resolve, reject) => heldMaps.push({ outcome, resolve, reject }));
    });
    wrap(buffer, "getMappedRange", function (range, ...args) {
      count("getMappedRange");
      if (bufferFaults.range !== undefined) return bufferFaults.range();
      return range.apply(this, args);
    });
    return buffer;
  });
  wrap(device, "createTexture", function (original, ...args) {
    if (bufferFaults.texture !== undefined) return bufferFaults.texture();
    return original.apply(this, args);
  });
  wrap(device, "createComputePipelineAsync", function (original, ...args) {
    if (bufferFaults.pipeline !== undefined) return asked(bufferFaults.pipeline());
    return asked(original.apply(this, args));
  });
  wrap(device, "createShaderModule", function (original, ...args) {
    const module = original.apply(this, args);
    wrap(module, "getCompilationInfo", function (info) {
      return asked(bufferFaults.compilation === undefined ? info.call(this) : bufferFaults.compilation());
    });
    return module;
  });
  wrap(device, "createTexture", function (original, ...args) {
    const texture = original.apply(this, args);
    wrap(texture, "createView", function (view, ...rest) {
      if (bufferFaults.view !== undefined) return bufferFaults.view();
      return view.apply(this, rest);
    });
    return texture;
  });
  wrap(device, "createRenderPipeline", function (original, ...args) {
    if (bufferFaults.render !== undefined) return bufferFaults.render();
    return original.apply(this, args);
  });
  wrap(device, "createRenderPipelineAsync", function (original, ...args) {
    if (bufferFaults.renderAsync !== undefined) return asked(bufferFaults.renderAsync());
    return asked(original.apply(this, args));
  });
  // Immediates on a render pass or a bundle encoder: refused, or missing.
  const immediates = (encoder) => {
    if (bufferFaults.noImmediates === true) {
      globalThis.Object.defineProperty(encoder, "setImmediates", { configurable: true, value: undefined });
    } else if (typeof encoder.setImmediates === "function") {
      wrap(encoder, "setImmediates", function (set, ...data) {
        if (bufferFaults.immediates !== undefined) return bufferFaults.immediates();
        return set.apply(this, data);
      });
    }
    return encoder;
  };
  wrap(device, "createRenderBundleEncoder", function (original, ...args) {
    if (bufferFaults.bundle !== undefined) return bufferFaults.bundle();
    return immediates(original.apply(this, args));
  });
  wrap(device, "createCommandEncoder", function (original, ...args) {
    count("createCommandEncoder");
    const encoder = original.apply(this, args);
    wrap(encoder, "beginRenderPass", function (begin, ...rest) {
      return immediates(begin.apply(this, rest));
    });
    wrap(encoder, "beginComputePass", function (begin, ...rest) {
      const pass = begin.apply(this, rest);
      if (bufferFaults.noImmediates === true) globalThis.Object.defineProperty(pass, "setImmediates", { configurable: true, value: undefined });
      if (typeof pass.setImmediates === "function") {
        wrap(pass, "setImmediates", function (set, ...data) {
          if (bufferFaults.immediates !== undefined) return bufferFaults.immediates();
          return set.apply(this, data);
        });
      }
      return pass;
    });
    return encoder;
  });
  const queue = device.queue;
  wrap(queue, "writeBuffer", function (original, ...args) {
    count("writeBuffer");
    if (bufferFaults.write !== undefined) return bufferFaults.write();
    return original.apply(this, args);
  });
  wrap(queue, "copyExternalImageToTexture", function (original, ...args) {
    count("copyExternalImageToTexture");
    if (bufferFaults.copyExternal !== undefined) return bufferFaults.copyExternal();
    return original.apply(this, args);
  });
  wrap(device, "importExternalTexture", function (original, ...args) {
    count("importExternalTexture");
    if (bufferFaults.importExternal !== undefined) return bufferFaults.importExternal();
    return original.apply(this, args);
  });
  wrap(queue, "submit", function (original, ...args) {
    count("submit");
    return original.apply(this, args);
  });
  wrap(queue, "onSubmittedWorkDone", function (original, ...args) {
    return asked(bufferFaults.workDone === undefined ? original.apply(this, args) : bufferFaults.workDone());
  });
  let pushes = 0;
  wrap(device, "pushErrorScope", function (original, filter) {
    pushes += 1;
    if (pushes === pushThrowsAt) throw new globalThis.TypeError(`injected failure of push ${pushes}`);
    stack.push(filter);
    return original.call(this, filter);
  });
  wrap(device, "popErrorScope", function (original) {
    const filter = stack.pop();
    const fault = popFaults[filter];
    const native = asked(original.call(this));
    if (!holdPops) return answer(native, fault);
    // A held pop's fault is applied only when it is released, so no
    // rejected promise waits unhandled in the stub while it is held.
    return new globalThis.Promise((resolve, reject) => held.push({ filter, native, fault, resolve, reject }));
  });
  wrap(device, "createSampler", function (original, ...args) {
    callCounts.createSampler = (callCounts.createSampler ?? 0) + 1;
    if (createThrows) {
      globalThis.queueMicrotask(() => globalThis.console.log(`error scopes left open after the throw: ${stack.length}`));
      throw new globalThis.RangeError("injected createSampler failure");
    }
    return original.apply(this, args);
  });
};

// Every `webgpu` context the page gets, on either host: null while
// "context-null" holds, and its `configure` and `getCurrentTexture`
// faulted while "configure-type-error" or "current-unlisted" hold.
let contextNull = false;
const instrumentedContexts = new globalThis.WeakSet();
const instrumentContext = (context) => {
  if (context === null || instrumentedContexts.has(context)) return context;
  instrumentedContexts.add(context);
  wrap(context, "configure", function (original, ...args) {
    if (bufferFaults.configure !== undefined) return bufferFaults.configure();
    return original.apply(this, args);
  });
  wrap(context, "getCurrentTexture", function (original, ...args) {
    if (bufferFaults.current !== undefined) return bufferFaults.current();
    return original.apply(this, args);
  });
  return context;
};
let contextsWrapped = false;
const wrapContexts = () => {
  if (contextsWrapped) return;
  contextsWrapped = true;
  for (const owner of [globalThis.HTMLCanvasElement, globalThis.OffscreenCanvas]) {
    if (owner === undefined || typeof owner.prototype.getContext !== "function") continue;
    wrap(owner.prototype, "getContext", function (original, kind, ...rest) {
      if (kind !== "webgpu") return original.call(this, kind, ...rest);
      if (contextNull) return null;
      return instrumentContext(original.call(this, kind, ...rest));
    });
  }
};

// A flag a microtask sets, for a fixture to see that no microtask ran
// between two points of one synchronous callback.
let microtaskRan = true;
export const armMicrotask = (_unit) => {
  microtaskRan = false;
  globalThis.queueMicrotask(() => {
    microtaskRan = true;
  });
  return null;
};
export const microtaskHasRun = (_unit) => microtaskRan;

let host = null;
let hostRequestAdapter = null;
// The page's own `isSecureContext`, as the host defined it, before any fault.
let secureContext = null;

// The host of this page as no fault has touched it: the fake's
// `navigator.gpu`, made once, or the native one; the secure context the
// page has; and every device's `lost` replaced while "lost-controlled"
// holds. Each `inject` starts from it, so faults never pile up.
function prepare() {
  renderLog.length = 0;
  raisedFlags.clear();
  contextNull = false;
  if (!native()) fakeCanvases();
  if (!native()) fakeMedia();
  wrapContexts();
  controlLoss = false;
  popFaults = {};
  holdPops = false;
  pushThrowsAt = 0;
  createThrows = false;
  moreFeatures = false;
  holdRequests = false;
  bufferFaults = {};
  holdMaps = false;
  if (native()) {
    delete globalThis.navigator.gpu;
    if (secureContext === null) secureContext = globalThis.Object.getOwnPropertyDescriptor(globalThis, "isSecureContext") ?? false;
    if (secureContext === false) delete globalThis.isSecureContext;
    else globalThis.Object.defineProperty(globalThis, "isSecureContext", secureContext);
  } else {
    globalThis.Object.defineProperty(globalThis, "isSecureContext", { configurable: true, value: true });
    globalThis.Object.defineProperty(globalThis, "GPUValidationError", { configurable: true, value: FakeValidationError });
    globalThis.Object.defineProperty(globalThis, "GPUOutOfMemoryError", { configurable: true, value: FakeOutOfMemoryError });
    globalThis.Object.defineProperty(globalThis, "GPUInternalError", { configurable: true, value: FakeInternalError });
    globalThis.Object.defineProperty(globalThis, "GPUPipelineError", { configurable: true, value: FakePipelineError });
  }
  if (host !== null) {
    if (!native()) globalThis.Object.defineProperty(globalThis.navigator, "gpu", { configurable: true, value: host });
    host.requestAdapter = hostRequestAdapter;
    return host;
  }
  if (!native()) globalThis.Object.defineProperty(globalThis.navigator, "gpu", { configurable: true, value: fakeGpu() });
  host = globalThis.navigator.gpu;
  // Next to the host: the host answers, and a held request waits after it
  // for `releaseRequest`; the loss control and every fault see it after.
  const hostRequest = host.requestAdapter;
  host.requestAdapter = function (...args) {
    return holding(() => hostRequest.apply(this, args)).then((adapter) => {
      if (adapter !== null) wrap(adapter, "requestDevice", function (request, ...rest) {
        return holding(() => request.apply(this, rest));
      });
      return adapter;
    });
  };
  onAdapters(host, function (original, ...args) {
    return original.apply(this, args).then((device) => {
      instrument(device);
      // A destroyed device's loss is an answer `later` waits for.
      wrap(device, "destroy", function (destroy) {
        if (!controlledDevices.has(this)) asked(this.lost);
        return destroy.call(this);
      });
      if (controlLoss) {
        controlLoss = false;
        controlledDevices.add(device);
        const entry = {};
        const lost = new globalThis.Promise((done, fail) => {
          entry.resolve = done;
          entry.reject = fail;
        });
        globalThis.Object.defineProperty(device, "lost", { configurable: true, value: lost });
        controlled.push(entry);
      }
      return device;
    });
  }, false);
  hostRequestAdapter = host.requestAdapter;
  return host;
}

export const inject = (scenarios) => {
  const gpu = prepare();
  for (const scenario of scenarios.split(",")) {
    const fault = faults[scenario];
    if (fault === undefined) throw new globalThis.Error(`GpuHost.inject: no scenario "${scenario}"`);
    fault(gpu);
  }
  return null;
};

// A pop's answer: the host's, or the fault's once the host has answered.
const answer = (native, fault) => (fault === undefined ? native : native.then(() => fault()));
const settle = (entry) => answer(entry.native, entry.fault).then(entry.resolve, entry.reject);

// Every held pop, the latest first, each settled as its host pop did.
export const releasePops = (_unit) => {
  let chain = globalThis.Promise.resolve();
  for (const entry of held.splice(0).reverse()) chain = chain.then(() => settle(entry));
  return null;
};

export const calls = (name) => callCounts[name] ?? 0;

export const lose = (reason) => {
  const entry = controlled[controlled.length - 1];
  if (entry === undefined) throw new globalThis.Error("GpuHost.lose: no device was made under \"lost-controlled\"");
  if (reason === "reject") entry.reject(new globalThis.DOMException("injected rejection of lost", "AbortError"));
  else entry.resolve(lostInfo(reason, "injected loss"));
  return null;
};

// Settle the latest held request: `"host"` as the host did, or rejected
// with an `OperationError` (`"reject-operation"`) or a `DOMException` the
// ledger does not list (`"reject-unlisted"`).
export const releaseRequest = (how) => {
  const entry = heldRequests.pop();
  if (entry === undefined) throw new globalThis.Error("GpuHost.releaseRequest: no request is held");
  if (how === "host") asked(entry.call()).then(entry.resolve, entry.reject);
  else if (how === "reject-operation") entry.reject(new globalThis.DOMException("injected device refusal", "OperationError"));
  else if (how === "reject-unlisted") entry.reject(new globalThis.DOMException("injected unlisted refusal", "NotSupportedError"));
  else throw new globalThis.Error(`GpuHost.releaseRequest: no way "${how}"`);
  return null;
};

// Call `f` once every request the host was asked has been answered and
// 64 more microtasks have run: by then each reaction an answer set off has
// run, the engine's included.
export const later = (f) => {
  let chain = globalThis.Promise.allSettled(hostAnswers.slice());
  for (let i = 0; i < 64; i += 1) chain = chain.then(() => null);
  chain.then(() => f(null));
  return null;
};

// The latest held pop of `filter` alone, settled as its host pop did.
export const releasePop = (filter) => {
  const at = held.findLastIndex((entry) => entry.filter === filter);
  if (at < 0) throw new globalThis.Error(`GpuHost.releasePop: no "${filter}" pop is held`);
  settle(held.splice(at, 1)[0]);
  return null;
};

// Every held map, in the order they were asked, each settled as its
// host map did.
export const releaseMaps = (_unit) => {
  for (const settle of heldFakeMaps.splice(0)) settle();
  for (const entry of heldMaps.splice(0)) entry.outcome.then(entry.resolve, entry.reject);
  return null;
};

// Storage a host can make and `Binary` never does (#1268): a resizable
// `ArrayBuffer`, and a growable `SharedArrayBuffer` where the page has
// shared memory. Neither ever resizes here.
export const resizable = (bytes) => new globalThis.ArrayBuffer(bytes, { maxByteLength: bytes * 2 });
export const sharedMemory = (_unit) => globalThis.SharedArrayBuffer !== undefined;
export const growable = (bytes) => new globalThis.SharedArrayBuffer(bytes, { maxByteLength: bytes * 2 });
export const resizableBytes = (bytes) => new globalThis.Uint8Array(resizable(bytes));
export const growableBytes = (bytes) => new globalThis.Uint8Array(growable(bytes));
export const resizableWords = (count) => new globalThis.Uint32Array(resizable(count * 4));

const noted = [];
export const note = (line) => {
  noted.push(line);
  return null;
};
export const notes = (_unit) => noted.splice(0);

let keptBuffer = null;
export const keep = (buffer) => {
  keptBuffer = buffer;
  return null;
};
export const kept = (_unit) => keptBuffer;

// The render commands issued since the last call, oldest first.
export const commands = (_unit) => renderLog.splice(0);

let keptBatchValue = null;
export const keepBatch = (batch) => {
  keptBatchValue = batch;
  return null;
};
export const keptBatch = (_unit) => keptBatchValue;


// A native call the engine never makes: a sampler the device refuses, made
// outside every error scope, so its validation error is uncaptured.
export const escape = (device) => {
  device.createSampler({ lodMinClamp: 10, lodMaxClamp: 1 });
  // An answer of the GPU process after the error, for the page to wait on.
  device.queue.onSubmittedWorkDone();
  return null;
};

// An `uncapturederror` event whose error is a plain object named like a GPU
// error, dispatched on the device.
export const escapeSpoofed = (device) => {
  const event = new globalThis.Event("uncapturederror");
  globalThis.Object.defineProperty(event, "error", { value: { name: "GPUValidationError", message: "a plain object, not a GPUValidationError" } });
  device.dispatchEvent(event);
  return null;
};

// A native pop the engine never makes: the device's innermost scope, which
// is the engine's, popped behind its back.
export const popBehind = (device) => {
  device.popErrorScope().then(null, () => null);
  return null;
};

// Every instrumented device's error scope stack, as the page pushed it.
const scopeStacks = new globalThis.WeakMap();

// Log how many error scopes of the device are open three tasks later:
// after a throw, once the runtime's teardown (a task after the throw) ran
// the finalisers of every fiber.
export const logScopesLater = (device) => {
  const log = () => globalThis.console.log(`error scopes open: ${(scopeStacks.get(device) ?? []).length}`);
  globalThis.setTimeout(() => globalThis.setTimeout(() => globalThis.setTimeout(log, 0), 0), 0);
  return null;
};

// Throw a native `TypeError`, as application code might.
export const fail = (message) => {
  throw new globalThis.TypeError(message);
};

// How many error scopes of the device are open now, as the page pushed them.
export const openScopes = (device) => (scopeStacks.get(device) ?? []).length;

// Write `line` to the console, where a page that stops still shows it.
export const log = (line) => {
  globalThis.console.log(line);
  return null;
};

// Named flags a page raises and reads, cleared by each `inject`: what lets
// one fiber wait for another without joining it.
const raisedFlags = new globalThis.Set();
export const raise = (name) => {
  raisedFlags.add(name);
  return null;
};
export const raised = (name) => raisedFlags.has(name);

// ---- Media sources (docs/design/webgpu.md §8; ledger §6) -------------------
//
// The image and video elements the external-image fixtures copy and import,
// made from the opaque RGBA pixels a fixture gives. In Chrome an image is
// the driver's `/_media/image.bmp`, a BMP of those pixels, from the page's
// origin or from another one (`localhost`, which taints it); a video plays a
// stream captured from a canvas holding them. On the fake host neither
// loads: an element is given the state the fixture asks for, and the fake's
// copy reads its size from it. Where the page lacks them (happy-dom), a
// fake `VideoFrame`, `ImageBitmap`, `createImageBitmap` and `ImageData`
// keep the shapes `Browser.Image` and `Browser.Video` read.
const TEXTURE_COPY_DST = 2;
const TEXTURE_RENDER_ATTACHMENT = 16;
// Sources the fake host treats as tainted by another origin.
const taintedMedia = new globalThis.WeakSet();
const mediaSize = (image) => {
  if (image instanceof globalThis.HTMLImageElement) return { width: image.naturalWidth, height: image.naturalHeight };
  if (image instanceof globalThis.HTMLVideoElement) return { width: image.videoWidth, height: image.videoHeight };
  if (image.displayWidth !== undefined) return { width: image.displayWidth, height: image.displayHeight };
  return { width: image.width, height: image.height };
};
const closedMedia = (image) => image.codedWidth === 0 || (image.close !== undefined && image.width === 0);

// A load in real time, which the driver's settle of a step waits for as
// it waits for a native WebGPU promise (its count of pending ones): the
// release that ends the wait.
const awaited = () => {
  const record = globalThis.__beniHarness?.gpu;
  if (record === undefined) return () => {};
  record.pending += 1;
  let released = false;
  return () => {
    if (!released) record.pending -= 1;
    released = true;
  };
};

let mediaCount = 0;
const hex = (pixels) => globalThis.Array.from(new globalThis.Uint8Array(pixels), (b) => b.toString(16).padStart(2, "0")).join("");
// The driver's BMP of `pixels`, `width` wide, from `origin`.
const mediaUrl = (origin, pixels, width) => {
  mediaCount += 1;
  return `${origin}/_media/image.bmp?w=${width}&px=${hex(pixels)}&n=${mediaCount}`;
};

export const image = (kind, pixels, width, done) => {
  const element = new globalThis.Image();
  const height = pixels.byteLength / 4 / width;
  if (kind === "empty") return void globalThis.queueMicrotask(() => done(element));
  if (!native()) {
    const states = {
      same: { complete: true, currentSrc: "fake:image", naturalWidth: width, naturalHeight: height },
      cross: { complete: true, currentSrc: "fake:cross", naturalWidth: width, naturalHeight: height },
      broken: { complete: true, currentSrc: "fake:broken", naturalWidth: 0, naturalHeight: 0 },
      loading: { complete: false, currentSrc: "fake:loading", naturalWidth: 0, naturalHeight: 0 },
    };
    const state = states[kind];
    if (state === undefined) throw new globalThis.Error(`GpuHost.image: no kind "${kind}"`);
    for (const [name, value] of globalThis.Object.entries(state)) globalThis.Object.defineProperty(element, name, { configurable: true, value });
    if (kind === "cross") taintedMedia.add(element);
    return void globalThis.queueMicrotask(() => done(element));
  }
  const here = globalThis.location.origin;
  const there = `http://localhost:${globalThis.location.port}`;
  if (kind === "same") element.src = mediaUrl(here, pixels, width);
  else if (kind === "cross") element.src = mediaUrl(there, pixels, width);
  else if (kind === "broken") element.src = `${here}/_media/missing.bmp?n=${(mediaCount += 1)}`;
  else if (kind === "loading") {
    // The driver holds this one back, so it is still loading when used.
    element.src = `${mediaUrl(here, pixels, width)}&delay=5000`;
    return void globalThis.queueMicrotask(() => done(element));
  } else throw new globalThis.Error(`GpuHost.image: no kind "${kind}"`);
  const release = awaited();
  element.onload = () => {
    release();
    done(element);
  };
  element.onerror = () => {
    release();
    done(element);
  };
};

export const video = (kind, pixels, width, done) => {
  const element = globalThis.document.createElement("video");
  const height = pixels.byteLength / 4 / width;
  if (kind === "empty") return void globalThis.queueMicrotask(() => done(element));
  if (kind !== "ready") throw new globalThis.Error(`GpuHost.video: no kind "${kind}"`);
  if (!native()) {
    for (const [name, value] of globalThis.Object.entries({ readyState: 4, videoWidth: width, videoHeight: height }))
      globalThis.Object.defineProperty(element, name, { configurable: true, value });
    return void globalThis.queueMicrotask(() => done(element));
  }
  const canvas = globalThis.document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  const paint = () => context.putImageData(new globalThis.ImageData(new globalThis.Uint8ClampedArray(pixels.slice(0)), width, height), 0, 0);
  paint();
  // A captured canvas sends a frame when it is painted: paint it on a timer
  // until the element has shown one.
  const timer = globalThis.setInterval(paint, 20);
  element.muted = true;
  element.srcObject = canvas.captureStream();
  const release = awaited();
  const shown = () => {
    if (element.readyState >= 2 && element.videoWidth === width) {
      globalThis.clearInterval(timer);
      release();
      done(element);
    } else element.requestVideoFrameCallback(shown);
  };
  element.requestVideoFrameCallback(shown);
  element.play();
};

// Fakes of the media classes happy-dom lacks or keeps apart from its own
// constructors, for the fake host only.
function FakeImageData(data, width, height, settings) {
  this.data = data;
  this.width = width;
  this.height = height ?? data.length / 4 / width;
  this.colorSpace = settings?.colorSpace ?? "srgb";
  this.pixelFormat = settings?.pixelFormat ?? "rgba-unorm8";
}
function FakeImageBitmap(width, height) {
  this.width = width;
  this.height = height;
}
FakeImageBitmap.prototype.close = function () {
  this.width = 0;
  this.height = 0;
};
function FakeVideoFrame(source, init) {
  const size = mediaSize(source);
  if (size.width === 0) throw new globalThis.DOMException("the source is closed", "InvalidStateError");
  this.codedWidth = size.width;
  this.codedHeight = size.height;
  this.displayWidth = size.width;
  this.displayHeight = size.height;
  this.timestamp = init?.timestamp ?? source.timestamp ?? 0;
  this.duration = init?.duration ?? null;
  this.rotation = init?.rotation ?? 0;
  this.flip = init?.flip ?? false;
  this.format = "RGBA";
}
FakeVideoFrame.prototype.close = function () {
  this.codedWidth = 0;
  this.codedHeight = 0;
  this.displayWidth = 0;
  this.displayHeight = 0;
  this.format = null;
};
FakeVideoFrame.prototype.clone = function () {
  if (this.codedWidth === 0) throw new globalThis.DOMException("the frame is closed", "InvalidStateError");
  return new FakeVideoFrame(this, { timestamp: this.timestamp });
};
let mediaFaked = false;
const fakeMedia = () => {
  if (mediaFaked) return;
  mediaFaked = true;
  globalThis.ImageData = FakeImageData;
  globalThis.ImageBitmap = FakeImageBitmap;
  globalThis.VideoFrame = FakeVideoFrame;
  globalThis.createImageBitmap = (source, ...rest) => {
    const size = mediaSize(source);
    if (size.width === 0 || size.height === 0) return globalThis.Promise.reject(new globalThis.DOMException("the source has no pixels", "InvalidStateError"));
    const crop = rest.length >= 4 ? { width: globalThis.Math.abs(rest[2]), height: globalThis.Math.abs(rest[3]) } : size;
    return globalThis.Promise.resolve(new FakeImageBitmap(crop.width, crop.height));
  };
};
