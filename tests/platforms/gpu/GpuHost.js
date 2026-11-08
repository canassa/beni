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
  "device-range-error": (gpu) => onAdapters(gpu, () => globalThis.Promise.reject(new globalThis.RangeError("injected range error"))),
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
  onAdapters(host, function (original, ...args) {
    return original.apply(this, args).then((device) => {
      if (controlLoss) {
        controlLoss = false;
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

export const inject = (scenario) => {
  const fault = faults[scenario];
  if (fault === undefined) throw new globalThis.Error(`GpuHost.inject: no scenario "${scenario}"`);
  fault(prepare());
  return null;
};

export const lose = (reason) => {
  const entry = controlled[controlled.length - 1];
  if (entry === undefined) throw new globalThis.Error("GpuHost.lose: no device was made under \"lost-controlled\"");
  if (reason === "reject") entry.reject(new globalThis.DOMException("injected rejection of lost", "AbortError"));
  else entry.resolve(lostInfo(reason, "injected loss"));
  return null;
};
