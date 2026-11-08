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
  return device;
};

const fakeAdapter = () => {
  const adapter = {
    features: new globalThis.Set(adapterFeatures),
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

let host = null;
let hostRequestAdapter = null;
// The page's own `isSecureContext`, as the host defined it, before any fault.
let secureContext = null;

// The host of this page as no fault has touched it: the fake's
// `navigator.gpu`, made once, or the native one; the secure context the
// page has; and every device's `lost` replaced while "lost-controlled"
// holds. Each `inject` starts from it, so faults never pile up.
function prepare() {
  controlLoss = false;
  holdRequests = false;
  if (native()) {
    delete globalThis.navigator.gpu;
    if (secureContext === null) secureContext = globalThis.Object.getOwnPropertyDescriptor(globalThis, "isSecureContext") ?? false;
    if (secureContext === false) delete globalThis.isSecureContext;
    else globalThis.Object.defineProperty(globalThis, "isSecureContext", secureContext);
  } else {
    globalThis.Object.defineProperty(globalThis, "isSecureContext", { configurable: true, value: true });
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
