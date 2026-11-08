// The WebGPU fixtures' host (docs/design/webgpu.md §10). `inject` prepares
// it once per page: under `zig build test-webgpu` the driver sets
// `__beniWebGpuNative` and the host is Chrome's own WebGPU; anywhere else
// it is the fake below, which keeps to the IDL's shapes and resolves every
// promise on a microtask, so the gates' happy-dom can run the engine's
// wrapper logic. A fault then wraps the native method it is about, on
// whichever host is there.
//
// The fake is not WebGPU: it validates nothing a fixture does not ask it to.

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
  device.destroy = () => {
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
  const report = (filter, error) => {
    for (let i = scopes.length - 1; i >= 0; i -= 1) {
      if (scopes[i].filter !== filter) continue;
      if (scopes[i].error === null) scopes[i].error = error;
      return;
    }
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
        globalThis.queueMicrotask(() => {
          if (s.pending !== pending) return;
          s.pending = null;
          s.mapState = "mapped";
          s.mode = mode;
          s.offset = offset;
          s.length = length;
          resolve(undefined);
        });
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
      return plainObject(d.label);
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
    encoder.copyBufferToTexture = () => {};
    encoder.copyTextureToBuffer = () => {};
    encoder.copyTextureToTexture = () => {};
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
const fakeContext = (canvas) => {
  let config = null;
  let current = null;
  let currentSize = "";
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
    const size = `${canvas.width}x${canvas.height}`;
    if (current === null || currentSize !== size) {
      current = config.device.createTexture({ size: [canvas.width, canvas.height], format: config.format, usage: config.usage });
      currentSize = size;
      const presented = current;
      globalThis.setTimeout(() => {
        if (current === presented) current = null;
      }, 0);
    }
    return current;
  };
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
      if (kind === "webgpu") return webgpuContext(this);
      return getContext === undefined ? null : getContext.call(this, kind, ...rest);
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
  return kind === "webgpu" ? webgpuContext(this) : null;
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
let createThrows = false;
let moreFeatures = false;
// The buffer and queue faults of the scenario, by the native call they
// replace; whether map outcomes are held until `releaseMaps`.
let bufferFaults = {};
let holdMaps = false;
const heldMaps = [];
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
  wrap(queue, "submit", function (original, ...args) {
    count("submit");
    return original.apply(this, args);
  });
  wrap(queue, "onSubmittedWorkDone", function (original, ...args) {
    return asked(bufferFaults.workDone === undefined ? original.apply(this, args) : bufferFaults.workDone());
  });
  wrap(device, "pushErrorScope", function (original, filter) {
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
  contextNull = false;
  if (!native()) fakeCanvases();
  wrapContexts();
  controlLoss = false;
  popFaults = {};
  holdPops = false;
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

// TEMPORARY probe of a native canvas's onSubmittedWorkDone.
export const rawProbe = (_unit) => {
  const out = globalThis.document.createElement("pre");
  globalThis.document.body.appendChild(out);
  const say = (line) => {
    out.textContent += line + ";";
  };
  const run = (name, attach, use, delay) =>
    globalThis.navigator.gpu.requestAdapter().then((adapter) => adapter.requestDevice()).then((device) => {
      const canvas = globalThis.document.createElement("canvas");
      canvas.width = 4;
      canvas.height = 4;
      if (attach) globalThis.document.body.appendChild(canvas);
      const ctx = canvas.getContext("webgpu");
      ctx.configure({ device, format: "rgba8unorm" });
      const tex = ctx.getCurrentTexture();
      const enc = device.createCommandEncoder();
      if (use) {
        const p = enc.beginRenderPass({ colorAttachments: [{ view: tex.createView(), loadOp: "clear", storeOp: "store" }] });
        p.end();
      }
      device.queue.submit([enc.finish()]);
      const wait = () => device.queue.onSubmittedWorkDone();
      const done = delay ? new globalThis.Promise((r) => globalThis.setTimeout(r, 50)).then(wait) : wait();
      return done.then(() => say(`${name}: ok`), (e) => say(`${name}: ${e.name} ${e.message}`));
    }).then(null, (e) => say(`${name} threw: ${e.name} ${e.message}`));
  asked(run("detached-used-now", false, true, false));
  asked(run("detached-unused-now", false, false, false));
  asked(run("detached-used-later", false, true, true));
  asked(run("attached-used-now", true, true, false));
  return null;
};
