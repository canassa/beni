# WebGPU coverage inventory

Every declaration of the pinned [webgpu.idl](webgpu.idl), and every member,
overload, mixin inclusion and partial block of it, with the beni declaration
that covers it and a behavioural fixture that exercises that declaration, or
the later slice that will (`docs/design/webgpu.md` §1, §10, §10.1). The
signatures and defaults are the required surface; see
[the contract](../../webgpu.md) §2–§4 for translation rules and §6 for the
managed encoding and scope adapters.

Counts: 62 dictionary, 34 enum, 37 includes, 36 interface, 7 interface mixin, 5 namespace, 3 partial interface, 25 typedef.

**The gate.** `tests/gpu_coverage.zig`, part of `zig build gates`, reads this
file and the IDL and fails when:

- an IDL declaration, member, overload or mixin member has no row here, or a
  row names one the IDL does not have;
- a row has neither declarations and fixtures nor a later slice;
- a declaration does not exist: its module must be one that `browser-tea`
  re-exports, and the module must declare it `pub` (a function, a type, or a
  constructor of a type);
- a fixture does not exist (`tests/corpus/<path>`, with a golden), or no
  fixture of the row names one of the row's declarations in its own code
  (comments do not count; a type or constructor named in a test-platform
  module the fixture imports counts);
- a later slice is not one of the table below.

**How a row reads.** The first column is the IDL member: an attribute by its
name, an operation by its name and parameter names (so each overload has its
own row), `constructor(…)`, `setlike`, or the declaration's own name for the
declaration itself. A mixin's members are listed under each `includes` that
applies it, since each including interface needs its own binding. The second
column lists declarations, each `Gpu.Module.name`; the third lists fixtures
under `tests/corpus/`. A row whose second column is `later #N` waits for that
slice; its third column is `—`.

The members of each generated dictionary, enum value and flag constant are
checked one by one against the generated modules by `tests/gpu_bindings.zig`
(the census, §2.2); a row here ties the whole declaration to its behaviour.

## Later slices

| Slice | Issue | What it adds |
|---|---|---|
| workers | #1299 | WebGPU in worker realms: `WorkerNavigator.gpu`, worker surfaces and transfers (`webgpu.md` §2, §10) |
| WGSL | #1276 | Built-in WGSL validation and minification; no IDL row waits for it |
| performance | #2245 | Measurements and budgets; no IDL row waits for it |

## interface mixin `GPUObjectBase`

```webidl
attribute USVString label;
```

Bound on each interface that includes it, below.

## dictionary `GPUObjectDescriptorBase`

```webidl
USVString label = "";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUObjectDescriptorBase` | `Gpu.Types.ObjectDescriptorBase` | `browser/gpu/CoverageDescriptors` |

## enum `GPUFeatureName`

`"core-features-and-limits"`, `"depth-clip-control"`, `"depth32float-stencil8"`, `"texture-compression-bc"`, `"texture-compression-bc-sliced-3d"`, `"texture-compression-etc2"`, `"texture-compression-astc"`, `"texture-compression-astc-sliced-3d"`, `"timestamp-query"`, `"indirect-first-instance"`, `"shader-f16"`, `"rg11b10ufloat-renderable"`, `"bgra8unorm-storage"`, `"float32-filterable"`, `"float32-blendable"`, `"clip-distances"`, `"dual-source-blending"`, `"subgroups"`, `"texture-formats-tier1"`, `"texture-formats-tier2"`, `"primitive-index"`, `"texture-component-swizzle"`, `"subgroup-size-control"`, `"texture-compression-unaligned"`, `"atomic-vec2u-min-max"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUFeatureName` | `Gpu.Types.FeatureName` | `browser/gpu/AdapterAndDevice` |

## interface `GPUSupportedLimits`

```webidl
readonly attribute unsigned long maxTextureDimension1D;
readonly attribute unsigned long maxTextureDimension2D;
readonly attribute unsigned long maxTextureDimension3D;
readonly attribute unsigned long maxTextureArrayLayers;
readonly attribute unsigned long maxBindGroups;
readonly attribute unsigned long maxBindGroupsPlusVertexBuffers;
readonly attribute unsigned long maxImmediateSize;
readonly attribute unsigned long maxBindingsPerBindGroup;
readonly attribute unsigned long maxDynamicUniformBuffersPerPipelineLayout;
readonly attribute unsigned long maxDynamicStorageBuffersPerPipelineLayout;
readonly attribute unsigned long maxSampledTexturesPerShaderStage;
readonly attribute unsigned long maxSamplersPerShaderStage;
readonly attribute unsigned long maxStorageBuffersPerShaderStage;
readonly attribute unsigned long maxStorageBuffersInVertexStage;
readonly attribute unsigned long maxStorageBuffersInFragmentStage;
readonly attribute unsigned long maxStorageTexturesPerShaderStage;
readonly attribute unsigned long maxStorageTexturesInVertexStage;
readonly attribute unsigned long maxStorageTexturesInFragmentStage;
readonly attribute unsigned long maxUniformBuffersPerShaderStage;
readonly attribute unsigned long long maxUniformBufferBindingSize;
readonly attribute unsigned long long maxStorageBufferBindingSize;
readonly attribute unsigned long minUniformBufferOffsetAlignment;
readonly attribute unsigned long minStorageBufferOffsetAlignment;
readonly attribute unsigned long maxVertexBuffers;
readonly attribute unsigned long long maxBufferSize;
readonly attribute unsigned long maxVertexAttributes;
readonly attribute unsigned long maxVertexBufferArrayStride;
readonly attribute unsigned long maxInterStageShaderVariables;
readonly attribute unsigned long maxColorAttachments;
readonly attribute unsigned long maxColorAttachmentBytesPerSample;
readonly attribute unsigned long maxComputeWorkgroupStorageSize;
readonly attribute unsigned long maxComputeInvocationsPerWorkgroup;
readonly attribute unsigned long maxComputeWorkgroupSizeX;
readonly attribute unsigned long maxComputeWorkgroupSizeY;
readonly attribute unsigned long maxComputeWorkgroupSizeZ;
readonly attribute unsigned long maxComputeWorkgroupsPerDimension;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSupportedLimits` | `Gpu.Limits.Limits` | `browser/gpu/CoverageAttributes` |
| `maxTextureDimension1D` | `Gpu.Limits.limit`, `Gpu.Limits.MaxTextureDimension1D` | `browser/gpu/CoverageAttributes` |
| `maxTextureDimension2D` | `Gpu.Limits.limit`, `Gpu.Limits.MaxTextureDimension2D` | `browser/gpu/CoverageAttributes` |
| `maxTextureDimension3D` | `Gpu.Limits.limit`, `Gpu.Limits.MaxTextureDimension3D` | `browser/gpu/CoverageAttributes` |
| `maxTextureArrayLayers` | `Gpu.Limits.limit`, `Gpu.Limits.MaxTextureArrayLayers` | `browser/gpu/CoverageAttributes` |
| `maxBindGroups` | `Gpu.Limits.limit`, `Gpu.Limits.MaxBindGroups` | `browser/gpu/CoverageAttributes` |
| `maxBindGroupsPlusVertexBuffers` | `Gpu.Limits.limit`, `Gpu.Limits.MaxBindGroupsPlusVertexBuffers` | `browser/gpu/CoverageAttributes` |
| `maxImmediateSize` | `Gpu.Limits.limit`, `Gpu.Limits.MaxImmediateSize` | `browser/gpu/CoverageAttributes` |
| `maxBindingsPerBindGroup` | `Gpu.Limits.limit`, `Gpu.Limits.MaxBindingsPerBindGroup` | `browser/gpu/CoverageAttributes` |
| `maxDynamicUniformBuffersPerPipelineLayout` | `Gpu.Limits.limit`, `Gpu.Limits.MaxDynamicUniformBuffersPerPipelineLayout` | `browser/gpu/CoverageAttributes` |
| `maxDynamicStorageBuffersPerPipelineLayout` | `Gpu.Limits.limit`, `Gpu.Limits.MaxDynamicStorageBuffersPerPipelineLayout` | `browser/gpu/CoverageAttributes` |
| `maxSampledTexturesPerShaderStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxSampledTexturesPerShaderStage` | `browser/gpu/CoverageAttributes` |
| `maxSamplersPerShaderStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxSamplersPerShaderStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageBuffersPerShaderStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageBuffersPerShaderStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageBuffersInVertexStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageBuffersInVertexStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageBuffersInFragmentStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageBuffersInFragmentStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageTexturesPerShaderStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageTexturesPerShaderStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageTexturesInVertexStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageTexturesInVertexStage` | `browser/gpu/CoverageAttributes` |
| `maxStorageTexturesInFragmentStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageTexturesInFragmentStage` | `browser/gpu/CoverageAttributes` |
| `maxUniformBuffersPerShaderStage` | `Gpu.Limits.limit`, `Gpu.Limits.MaxUniformBuffersPerShaderStage` | `browser/gpu/CoverageAttributes` |
| `maxUniformBufferBindingSize` | `Gpu.Limits.limit`, `Gpu.Limits.MaxUniformBufferBindingSize` | `browser/gpu/CoverageAttributes` |
| `maxStorageBufferBindingSize` | `Gpu.Limits.limit`, `Gpu.Limits.MaxStorageBufferBindingSize` | `browser/gpu/CoverageAttributes` |
| `minUniformBufferOffsetAlignment` | `Gpu.Limits.limit`, `Gpu.Limits.MinUniformBufferOffsetAlignment` | `browser/gpu/CoverageAttributes` |
| `minStorageBufferOffsetAlignment` | `Gpu.Limits.limit`, `Gpu.Limits.MinStorageBufferOffsetAlignment` | `browser/gpu/CoverageAttributes` |
| `maxVertexBuffers` | `Gpu.Limits.limit`, `Gpu.Limits.MaxVertexBuffers` | `browser/gpu/CoverageAttributes` |
| `maxBufferSize` | `Gpu.Limits.limit`, `Gpu.Limits.MaxBufferSize` | `browser/gpu/CoverageAttributes` |
| `maxVertexAttributes` | `Gpu.Limits.limit`, `Gpu.Limits.MaxVertexAttributes` | `browser/gpu/CoverageAttributes` |
| `maxVertexBufferArrayStride` | `Gpu.Limits.limit`, `Gpu.Limits.MaxVertexBufferArrayStride` | `browser/gpu/CoverageAttributes` |
| `maxInterStageShaderVariables` | `Gpu.Limits.limit`, `Gpu.Limits.MaxInterStageShaderVariables` | `browser/gpu/CoverageAttributes` |
| `maxColorAttachments` | `Gpu.Limits.limit`, `Gpu.Limits.MaxColorAttachments` | `browser/gpu/CoverageAttributes` |
| `maxColorAttachmentBytesPerSample` | `Gpu.Limits.limit`, `Gpu.Limits.MaxColorAttachmentBytesPerSample` | `browser/gpu/CoverageAttributes` |
| `maxComputeWorkgroupStorageSize` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeWorkgroupStorageSize` | `browser/gpu/CoverageAttributes` |
| `maxComputeInvocationsPerWorkgroup` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeInvocationsPerWorkgroup` | `browser/gpu/CoverageAttributes` |
| `maxComputeWorkgroupSizeX` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeWorkgroupSizeX` | `browser/gpu/CoverageAttributes` |
| `maxComputeWorkgroupSizeY` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeWorkgroupSizeY` | `browser/gpu/CoverageAttributes` |
| `maxComputeWorkgroupSizeZ` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeWorkgroupSizeZ` | `browser/gpu/CoverageAttributes` |
| `maxComputeWorkgroupsPerDimension` | `Gpu.Limits.limit`, `Gpu.Limits.MaxComputeWorkgroupsPerDimension` | `browser/gpu/CoverageAttributes` |

## interface `GPUSupportedFeatures`

```webidl
readonly setlike<DOMString>;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSupportedFeatures` | `Gpu.Feature.Features` | `browser/gpu/CoverageAttributes` |
| `setlike` | `Gpu.Feature.has`, `Gpu.Feature.values` | `browser/gpu/CoverageAttributes` |

## interface `WGSLLanguageFeatures`

```webidl
readonly setlike<DOMString>;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `WGSLLanguageFeatures` | `Gpu.WgslFeature.WgslFeatures` | `browser/gpu/CoverageAttributes` |
| `setlike` | `Gpu.WgslFeature.has`, `Gpu.WgslFeature.values` | `browser/gpu/CoverageAttributes` |

## interface `GPUAdapterInfo`

```webidl
readonly attribute DOMString vendor;
readonly attribute DOMString architecture;
readonly attribute DOMString device;
readonly attribute DOMString description;
readonly attribute unsigned long subgroupMinSize;
readonly attribute unsigned long subgroupMaxSize;
readonly attribute boolean isFallbackAdapter;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUAdapterInfo` | `Gpu.Types.AdapterInfo` | `browser/gpu/CoverageAttributes` |
| `vendor` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `architecture` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `device` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `description` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `subgroupMinSize` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `subgroupMaxSize` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `isFallbackAdapter` | `Gpu.Adapter.info`, `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |

## interface mixin `NavigatorGPU`

```webidl
[SameObject, SecureContext] readonly attribute GPU gpu;
```

Bound on each interface that includes it, below.

## includes `Navigator includes NavigatorGPU;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `gpu` | `Gpu.available`, `Gpu.requestAdapter` | `browser/gpu/AdapterAndDevice` |

## includes `WorkerNavigator includes NavigatorGPU;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `gpu` | later #1299 | — |

## interface `GPU`

```webidl
Promise<GPUAdapter?> requestAdapter(optional GPURequestAdapterOptions options = {});
GPUTextureFormat getPreferredCanvasFormat();
[SameObject] readonly attribute WGSLLanguageFeatures wgslLanguageFeatures;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPU` | `Gpu.available` | `browser/gpu/AdapterAndDevice` |
| `requestAdapter(options)` | `Gpu.requestAdapter` | `browser/gpu/AdapterAndDevice` |
| `getPreferredCanvasFormat()` | `Gpu.preferredCanvasFormat` | `browser/gpu/AdapterAndDevice` |
| `wgslLanguageFeatures` | `Gpu.wgslLanguageFeatures` | `browser/gpu/AdapterAndDevice` |

## dictionary `GPURequestAdapterOptions`

```webidl
DOMString featureLevel = "core";
GPUPowerPreference powerPreference;
boolean forceFallbackAdapter = false;
boolean xrCompatible = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURequestAdapterOptions` | `Gpu.Types.AdapterOptions` | `browser/gpu/AdapterAndDevice` |

## enum `GPUPowerPreference`

`"low-power"`, `"high-performance"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPowerPreference` | `Gpu.Types.PowerPreference` | `browser/gpu/Conversions` |

## interface `GPUAdapter`

```webidl
[SameObject] readonly attribute GPUSupportedFeatures features;
[SameObject] readonly attribute GPUSupportedLimits limits;
[SameObject] readonly attribute GPUAdapterInfo info;
Promise<GPUDevice> requestDevice(optional GPUDeviceDescriptor descriptor = {});
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUAdapter` | `Gpu.Handle.Adapter` | `browser/gpu/AdapterAndDevice` |
| `features` | `Gpu.Adapter.features` | `browser/gpu/AdapterAndDevice` |
| `limits` | `Gpu.Adapter.limits` | `browser/gpu/AdapterAndDevice` |
| `info` | `Gpu.Adapter.info` | `browser/gpu/AdapterAndDevice` |
| `requestDevice(descriptor)` | `Gpu.Adapter.requestDevice` | `browser/gpu/AdapterAndDevice` |

## dictionary `GPUDeviceDescriptor` `: GPUObjectDescriptorBase`

```webidl
sequence<GPUFeatureName> requiredFeatures = [];
record<DOMString, (GPUSize64 or undefined)> requiredLimits = {};
GPUQueueDescriptor defaultQueue = {};
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDeviceDescriptor` | `Gpu.Types.DeviceDescriptor` | `browser/gpu/AdapterAndDevice` |

## interface `GPUDevice` `: EventTarget`

```webidl
[SameObject] readonly attribute GPUSupportedFeatures features;
[SameObject] readonly attribute GPUSupportedLimits limits;
[SameObject] readonly attribute GPUAdapterInfo adapterInfo;
[SameObject] readonly attribute GPUQueue queue;
undefined destroy();
GPUBuffer createBuffer(GPUBufferDescriptor descriptor);
GPUTexture createTexture(GPUTextureDescriptor descriptor);
GPUSampler createSampler(optional GPUSamplerDescriptor descriptor = {});
GPUExternalTexture importExternalTexture(GPUExternalTextureDescriptor descriptor);
GPUBindGroupLayout createBindGroupLayout(GPUBindGroupLayoutDescriptor descriptor);
GPUPipelineLayout createPipelineLayout(GPUPipelineLayoutDescriptor descriptor);
GPUBindGroup createBindGroup(GPUBindGroupDescriptor descriptor);
GPUShaderModule createShaderModule(GPUShaderModuleDescriptor descriptor);
GPUComputePipeline createComputePipeline(GPUComputePipelineDescriptor descriptor);
GPURenderPipeline createRenderPipeline(GPURenderPipelineDescriptor descriptor);
Promise<GPUComputePipeline> createComputePipelineAsync(GPUComputePipelineDescriptor descriptor);
Promise<GPURenderPipeline> createRenderPipelineAsync(GPURenderPipelineDescriptor descriptor);
GPUCommandEncoder createCommandEncoder(optional GPUCommandEncoderDescriptor descriptor = {});
GPURenderBundleEncoder createRenderBundleEncoder(GPURenderBundleEncoderDescriptor descriptor);
GPUQuerySet createQuerySet(GPUQuerySetDescriptor descriptor);
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDevice` | `Gpu.Handle.Device` | `browser/gpu/CoverageLabels` |
| `features` | `Gpu.Device.features` | `browser/gpu/CoverageAttributes` |
| `limits` | `Gpu.Device.limits` | `browser/gpu/CoverageAttributes` |
| `adapterInfo` | `Gpu.Device.adapterInfo` | `browser/gpu/CoverageAttributes` |
| `queue` | `Gpu.Device.queue` | `browser/gpu/AdapterAndDevice` |
| `destroy()` | `Gpu.Device.destroy` | `browser/gpu/CancelledRequests` |
| `createBuffer(descriptor)` | `Gpu.Device.createBuffer` | `browser/gpu/Batches` |
| `createTexture(descriptor)` | `Gpu.Device.createTexture` | `browser/gpu/ComputeCoverage` |
| `createSampler(descriptor)` | `Gpu.Device.createSampler` | `browser/gpu/CancelledChecked` |
| `importExternalTexture(descriptor)` | `Gpu.Frame.importExternalTexture` | `browser/gpu/ExternalTextureVideo` |
| `createBindGroupLayout(descriptor)` | `Gpu.Device.createBindGroupLayout` | `browser/gpu/CoverageDescriptors` |
| `createPipelineLayout(descriptor)` | `Gpu.Device.createPipelineLayout` | `browser/gpu/CoverageDescriptors` |
| `createBindGroup(descriptor)` | `Gpu.Device.createBindGroup` | `browser/gpu/ComputeCoverage` |
| `createShaderModule(descriptor)` | `Gpu.Device.createShaderModule` | `browser/gpu/Batches` |
| `createComputePipeline(descriptor)` | `Gpu.Device.createComputePipeline` | `browser/gpu/Batches` |
| `createRenderPipeline(descriptor)` | `Gpu.Device.createRenderPipeline` | `browser/gpu/CoverageDescriptors` |
| `createComputePipelineAsync(descriptor)` | `Gpu.Device.createComputePipelineAsync` | `browser/gpu/ComputeCoverage` |
| `createRenderPipelineAsync(descriptor)` | `Gpu.Device.createRenderPipelineAsync` | `browser/gpu/CoverageDescriptors` |
| `createCommandEncoder(descriptor)` | `Gpu.Encode.run` | `browser/gpu/ComputeCoverage` |
| `createRenderBundleEncoder(descriptor)` | `Gpu.Encode.bundle` | `browser/gpu/CoverageLabels` |
| `createQuerySet(descriptor)` | `Gpu.Device.createQuerySet` | `browser/gpu/ComputeCoverage` |

## includes `GPUDevice includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Device.label`, `Gpu.Device.setLabel` | `browser/gpu/CoverageLabels` |

## interface `GPUBuffer`

```webidl
readonly attribute GPUSize64Out size;
readonly attribute GPUFlagsConstant usage;
readonly attribute GPUBufferMapState mapState;
Promise<undefined> mapAsync(GPUMapModeFlags mode, optional GPUSize64 offset = 0, optional GPUSize64 size);
ArrayBuffer getMappedRange(optional GPUSize64 offset = 0, optional GPUSize64 size);
undefined unmap();
undefined destroy();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBuffer` | `Gpu.Handle.Buffer` | `browser/gpu/BufferRoundTrip` |
| `size` | `Gpu.Buffer.size` | `browser/gpu/BufferRoundTrip` |
| `usage` | `Gpu.Buffer.usage` | `browser/gpu/CoverageAttributes` |
| `mapState` | `Gpu.Buffer.mapState` | `browser/gpu/BufferRoundTrip` |
| `mapAsync(mode, offset, size)` | `Gpu.Buffer.map` | `browser/gpu/Batches` |
| `getMappedRange(offset, size)` | `Gpu.Buffer.getMappedRange` | `browser/gpu/Batches` |
| `unmap()` | `Gpu.Buffer.unmap` | `browser/gpu/Batches` |
| `destroy()` | `Gpu.Buffer.destroy` | `browser/gpu/BufferRefusals` |

## includes `GPUBuffer includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Buffer.label`, `Gpu.Buffer.setLabel` | `browser/gpu/CoverageLabels` |

## enum `GPUBufferMapState`

`"unmapped"`, `"pending"`, `"mapped"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferMapState` | `Gpu.Types.BufferMapState` | `browser/gpu/BufferRoundTrip` |

## dictionary `GPUBufferDescriptor` `: GPUObjectDescriptorBase`

```webidl
required GPUSize64 size;
required GPUBufferUsageFlags usage;
boolean mappedAtCreation = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferDescriptor` | `Gpu.Types.BufferDescriptor` | `browser/gpu/BufferRoundTrip` |

## typedef `GPUBufferUsageFlags`

```webidl
typedef [EnforceRange] unsigned long GPUBufferUsageFlags;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferUsageFlags` | `Gpu.Flags.BufferUsages` | `browser/gpu/CoverageAttributes` |

## namespace `GPUBufferUsage`

```webidl
const GPUFlagsConstant MAP_READ = 0x0001;
const GPUFlagsConstant MAP_WRITE = 0x0002;
const GPUFlagsConstant COPY_SRC = 0x0004;
const GPUFlagsConstant COPY_DST = 0x0008;
const GPUFlagsConstant INDEX = 0x0010;
const GPUFlagsConstant VERTEX = 0x0020;
const GPUFlagsConstant UNIFORM = 0x0040;
const GPUFlagsConstant STORAGE = 0x0080;
const GPUFlagsConstant INDIRECT = 0x0100;
const GPUFlagsConstant QUERY_RESOLVE = 0x0200;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferUsage` | `Gpu.Flags.BufferUsage` | `browser/gpu/BufferRoundTrip` |

## typedef `GPUMapModeFlags`

```webidl
typedef [EnforceRange] unsigned long GPUMapModeFlags;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUMapModeFlags` | `Gpu.Flags.MapModes` | `browser/gpu/BufferRefusals` |

## namespace `GPUMapMode`

```webidl
const GPUFlagsConstant READ = 0x0001;
const GPUFlagsConstant WRITE = 0x0002;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUMapMode` | `Gpu.Flags.MapMode` | `browser/gpu/BufferRefusals` |

## interface `GPUTexture`

```webidl
GPUTextureView createView(optional GPUTextureViewDescriptor descriptor = {});
undefined destroy();
readonly attribute GPUIntegerCoordinateOut width;
readonly attribute GPUIntegerCoordinateOut height;
readonly attribute GPUIntegerCoordinateOut depthOrArrayLayers;
readonly attribute GPUIntegerCoordinateOut mipLevelCount;
readonly attribute GPUSize32Out sampleCount;
readonly attribute GPUTextureDimension dimension;
readonly attribute GPUTextureFormat format;
readonly attribute GPUFlagsConstant usage;
readonly attribute (GPUTextureViewDimension or undefined) textureBindingViewDimension;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTexture` | `Gpu.Handle.Texture` | `browser/gpu/CanvasPage` |
| `createView(descriptor)` | `Gpu.Texture.createView` | `browser/gpu/CoverageDescriptors` |
| `destroy()` | `Gpu.Texture.destroy` | `browser/gpu/ComputeCoverage` |
| `width` | `Gpu.Texture.width` | `browser/gpu/CoverageAttributes` |
| `height` | `Gpu.Texture.height` | `browser/gpu/CoverageAttributes` |
| `depthOrArrayLayers` | `Gpu.Texture.depthOrArrayLayers` | `browser/gpu/CoverageAttributes` |
| `mipLevelCount` | `Gpu.Texture.mipLevelCount` | `browser/gpu/CoverageAttributes` |
| `sampleCount` | `Gpu.Texture.sampleCount` | `browser/gpu/CoverageAttributes` |
| `dimension` | `Gpu.Texture.dimension` | `browser/gpu/CoverageAttributes` |
| `format` | `Gpu.Texture.format` | `browser/gpu/CoverageAttributes` |
| `usage` | `Gpu.Texture.usage` | `browser/gpu/CoverageAttributes` |
| `textureBindingViewDimension` | `Gpu.Texture.textureBindingViewDimension` | `browser/gpu/CoverageAttributes` |

## includes `GPUTexture includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Texture.label`, `Gpu.Texture.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUTextureDescriptor` `: GPUObjectDescriptorBase`

```webidl
required GPUExtent3D size;
GPUIntegerCoordinate mipLevelCount = 1;
GPUSize32 sampleCount = 1;
GPUTextureDimension dimension = "2d";
required GPUTextureFormat format;
required GPUTextureUsageFlags usage;
sequence<GPUTextureFormat> viewFormats = [];
GPUTextureViewDimension textureBindingViewDimension;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureDescriptor` | `Gpu.Types.TextureDescriptor` | `browser/gpu/Batches` |

## enum `GPUTextureDimension`

`"1d"`, `"2d"`, `"3d"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureDimension` | `Gpu.Types.TextureDimension` | `browser/gpu/Conversions` |

## typedef `GPUTextureUsageFlags`

```webidl
typedef [EnforceRange] unsigned long GPUTextureUsageFlags;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureUsageFlags` | `Gpu.Flags.TextureUsages` | `browser/gpu/CoverageAttributes` |

## namespace `GPUTextureUsage`

```webidl
const GPUFlagsConstant COPY_SRC = 0x01;
const GPUFlagsConstant COPY_DST = 0x02;
const GPUFlagsConstant TEXTURE_BINDING = 0x04;
const GPUFlagsConstant STORAGE_BINDING = 0x08;
const GPUFlagsConstant RENDER_ATTACHMENT = 0x10;
const GPUFlagsConstant TRANSIENT_ATTACHMENT = 0x20;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureUsage` | `Gpu.Flags.TextureUsage` | `browser/gpu/Batches` |

## interface `GPUTextureView`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureView` | `Gpu.Handle.TextureView` | `browser/gpu/CoverageLabels` |

## includes `GPUTextureView includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.TextureView.label`, `Gpu.TextureView.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUTextureViewDescriptor` `: GPUObjectDescriptorBase`

```webidl
GPUTextureFormat format;
GPUTextureViewDimension dimension;
GPUTextureUsageFlags usage = 0;
GPUTextureAspect aspect = "all";
GPUIntegerCoordinate baseMipLevel = 0;
GPUIntegerCoordinate mipLevelCount;
GPUIntegerCoordinate baseArrayLayer = 0;
GPUIntegerCoordinate arrayLayerCount;
DOMString swizzle = "rgba";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureViewDescriptor` | `Gpu.Types.TextureViewDescriptor` | `browser/gpu/CanvasPage` |

## enum `GPUTextureViewDimension`

`"1d"`, `"2d"`, `"2d-array"`, `"cube"`, `"cube-array"`, `"3d"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureViewDimension` | `Gpu.Types.TextureViewDimension` | `browser/gpu/CoverageAttributes` |

## enum `GPUTextureAspect`

`"all"`, `"stencil-only"`, `"depth-only"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureAspect` | `Gpu.Types.TextureAspect` | `browser/gpu/CoverageDescriptors` |

## enum `GPUTextureFormat`

`"r8unorm"`, `"r8snorm"`, `"r8uint"`, `"r8sint"`, `"r16unorm"`, `"r16snorm"`, `"r16uint"`, `"r16sint"`, `"r16float"`, `"rg8unorm"`, `"rg8snorm"`, `"rg8uint"`, `"rg8sint"`, `"r32uint"`, `"r32sint"`, `"r32float"`, `"rg16unorm"`, `"rg16snorm"`, `"rg16uint"`, `"rg16sint"`, `"rg16float"`, `"rgba8unorm"`, `"rgba8unorm-srgb"`, `"rgba8snorm"`, `"rgba8uint"`, `"rgba8sint"`, `"bgra8unorm"`, `"bgra8unorm-srgb"`, `"rgb9e5ufloat"`, `"rgb10a2uint"`, `"rgb10a2unorm"`, `"rg11b10ufloat"`, `"rg32uint"`, `"rg32sint"`, `"rg32float"`, `"rgba16unorm"`, `"rgba16snorm"`, `"rgba16uint"`, `"rgba16sint"`, `"rgba16float"`, `"rgba32uint"`, `"rgba32sint"`, `"rgba32float"`, `"stencil8"`, `"depth16unorm"`, `"depth24plus"`, `"depth24plus-stencil8"`, `"depth32float"`, `"depth32float-stencil8"`, `"bc1-rgba-unorm"`, `"bc1-rgba-unorm-srgb"`, `"bc2-rgba-unorm"`, `"bc2-rgba-unorm-srgb"`, `"bc3-rgba-unorm"`, `"bc3-rgba-unorm-srgb"`, `"bc4-r-unorm"`, `"bc4-r-snorm"`, `"bc5-rg-unorm"`, `"bc5-rg-snorm"`, `"bc6h-rgb-ufloat"`, `"bc6h-rgb-float"`, `"bc7-rgba-unorm"`, `"bc7-rgba-unorm-srgb"`, `"etc2-rgb8unorm"`, `"etc2-rgb8unorm-srgb"`, `"etc2-rgb8a1unorm"`, `"etc2-rgb8a1unorm-srgb"`, `"etc2-rgba8unorm"`, `"etc2-rgba8unorm-srgb"`, `"eac-r11unorm"`, `"eac-r11snorm"`, `"eac-rg11unorm"`, `"eac-rg11snorm"`, `"astc-4x4-unorm"`, `"astc-4x4-unorm-srgb"`, `"astc-5x4-unorm"`, `"astc-5x4-unorm-srgb"`, `"astc-5x5-unorm"`, `"astc-5x5-unorm-srgb"`, `"astc-6x5-unorm"`, `"astc-6x5-unorm-srgb"`, `"astc-6x6-unorm"`, `"astc-6x6-unorm-srgb"`, `"astc-8x5-unorm"`, `"astc-8x5-unorm-srgb"`, `"astc-8x6-unorm"`, `"astc-8x6-unorm-srgb"`, `"astc-8x8-unorm"`, `"astc-8x8-unorm-srgb"`, `"astc-10x5-unorm"`, `"astc-10x5-unorm-srgb"`, `"astc-10x6-unorm"`, `"astc-10x6-unorm-srgb"`, `"astc-10x8-unorm"`, `"astc-10x8-unorm-srgb"`, `"astc-10x10-unorm"`, `"astc-10x10-unorm-srgb"`, `"astc-12x10-unorm"`, `"astc-12x10-unorm-srgb"`, `"astc-12x12-unorm"`, `"astc-12x12-unorm-srgb"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureFormat` | `Gpu.Types.TextureFormat` | `browser/gpu/Batches` |

## interface `GPUExternalTexture`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUExternalTexture` | `Gpu.Handle.ExternalTexture` | `browser/gpu/ExternalTextureFrame` |

## includes `GPUExternalTexture includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.ExternalTexture.label`, `Gpu.ExternalTexture.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUExternalTextureDescriptor` `: GPUObjectDescriptorBase`

```webidl
required (HTMLVideoElement or VideoFrame) source;
PredefinedColorSpace colorSpace = "srgb";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUExternalTextureDescriptor` | `Gpu.Types.ExternalTextureDescriptor` | `browser/gpu/ExternalTextureFrame` |

## interface `GPUSampler`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSampler` | `Gpu.Handle.Sampler` | `browser/gpu/CoverageDescriptors` |

## includes `GPUSampler includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Sampler.label`, `Gpu.Sampler.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUSamplerDescriptor` `: GPUObjectDescriptorBase`

```webidl
GPUAddressMode addressModeU = "clamp-to-edge";
GPUAddressMode addressModeV = "clamp-to-edge";
GPUAddressMode addressModeW = "clamp-to-edge";
GPUFilterMode magFilter = "nearest";
GPUFilterMode minFilter = "nearest";
GPUMipmapFilterMode mipmapFilter = "nearest";
float lodMinClamp = 0;
float lodMaxClamp = 32;
GPUCompareFunction compare;
[Clamp] unsigned short maxAnisotropy = 1;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSamplerDescriptor` | `Gpu.Types.SamplerDescriptor` | `browser/gpu/Batches` |

## enum `GPUAddressMode`

`"clamp-to-edge"`, `"repeat"`, `"mirror-repeat"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUAddressMode` | `Gpu.Types.AddressMode` | `browser/gpu/Conversions` |

## enum `GPUFilterMode`

`"nearest"`, `"linear"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUFilterMode` | `Gpu.Types.FilterMode` | `browser/gpu/CoverageDescriptors` |

## enum `GPUMipmapFilterMode`

`"nearest"`, `"linear"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUMipmapFilterMode` | `Gpu.Types.MipmapFilterMode` | `browser/gpu/CoverageDescriptors` |

## enum `GPUCompareFunction`

`"never"`, `"less"`, `"equal"`, `"less-equal"`, `"greater"`, `"not-equal"`, `"greater-equal"`, `"always"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCompareFunction` | `Gpu.Types.CompareFunction` | `browser/gpu/Conversions` |

## interface `GPUBindGroupLayout`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroupLayout` | `Gpu.Handle.BindGroupLayout` | `browser/gpu/FrameDependencies` |

## includes `GPUBindGroupLayout includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.BindGroupLayout.label`, `Gpu.BindGroupLayout.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUBindGroupLayoutDescriptor` `: GPUObjectDescriptorBase`

```webidl
required sequence<GPUBindGroupLayoutEntry> entries;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroupLayoutDescriptor` | `Gpu.Types.BindGroupLayoutDescriptor` | `browser/gpu/Batches` |

## dictionary `GPUBindGroupLayoutEntry`

```webidl
required GPUIndex32 binding;
required GPUShaderStageFlags visibility;
GPUBufferBindingLayout buffer;
GPUSamplerBindingLayout sampler;
GPUTextureBindingLayout texture;
GPUStorageTextureBindingLayout storageTexture;
GPUExternalTextureBindingLayout externalTexture;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroupLayoutEntry` | `Gpu.Types.BindGroupLayoutEntry` | `browser/gpu/Batches` |

## typedef `GPUShaderStageFlags`

```webidl
typedef [EnforceRange] unsigned long GPUShaderStageFlags;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUShaderStageFlags` | `Gpu.Flags.ShaderStages` | `browser/gpu/Batches` |

## namespace `GPUShaderStage`

```webidl
const GPUFlagsConstant VERTEX = 0x1;
const GPUFlagsConstant FRAGMENT = 0x2;
const GPUFlagsConstant COMPUTE = 0x4;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUShaderStage` | `Gpu.Flags.ShaderStage` | `browser/gpu/Batches` |

## enum `GPUBufferBindingType`

`"uniform"`, `"storage"`, `"read-only-storage"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferBindingType` | `Gpu.Types.BufferBindingType` | `browser/gpu/Batches` |

## dictionary `GPUBufferBindingLayout`

```webidl
GPUBufferBindingType type = "uniform";
boolean hasDynamicOffset = false;
GPUSize64 minBindingSize = 0;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferBindingLayout` | `Gpu.Types.BufferBindingLayout` | `browser/gpu/Batches` |

## enum `GPUSamplerBindingType`

`"filtering"`, `"non-filtering"`, `"comparison"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSamplerBindingType` | `Gpu.Types.SamplerBindingType` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUSamplerBindingLayout`

```webidl
GPUSamplerBindingType type = "filtering";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSamplerBindingLayout` | `Gpu.Types.SamplerBindingLayout` | `browser/gpu/CoverageDescriptors` |

## enum `GPUTextureSampleType`

`"float"`, `"unfilterable-float"`, `"depth"`, `"sint"`, `"uint"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureSampleType` | `Gpu.Types.TextureSampleType` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUTextureBindingLayout`

```webidl
GPUTextureSampleType sampleType = "float";
GPUTextureViewDimension viewDimension = "2d";
boolean multisampled = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTextureBindingLayout` | `Gpu.Types.TextureBindingLayout` | `browser/gpu/CoverageDescriptors` |

## enum `GPUStorageTextureAccess`

`"write-only"`, `"read-only"`, `"read-write"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStorageTextureAccess` | `Gpu.Types.StorageTextureAccess` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUStorageTextureBindingLayout`

```webidl
GPUStorageTextureAccess access = "write-only";
required GPUTextureFormat format;
GPUTextureViewDimension viewDimension = "2d";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStorageTextureBindingLayout` | `Gpu.Types.StorageTextureBindingLayout` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUExternalTextureBindingLayout`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUExternalTextureBindingLayout` | `Gpu.Types.ExternalTextureBindingLayout` | `browser/gpu/Conversions` |

## interface `GPUBindGroup`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroup` | `Gpu.Handle.BindGroup` | `browser/gpu/ComputeCoverage` |

## includes `GPUBindGroup includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.BindGroup.label`, `Gpu.BindGroup.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUBindGroupDescriptor` `: GPUObjectDescriptorBase`

```webidl
required GPUBindGroupLayout layout;
required sequence<GPUBindGroupEntry> entries;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroupDescriptor` | `Gpu.Types.BindGroupDescriptor` | `browser/gpu/Batches` |

## typedef `GPUBindingResource`

```webidl
typedef (GPUSampler or GPUTexture or GPUTextureView or GPUBuffer or GPUBufferBinding or GPUExternalTexture) GPUBindingResource;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindingResource` | `Gpu.Types.BindingResource` | `browser/gpu/Batches` |

## dictionary `GPUBindGroupEntry`

```webidl
required GPUIndex32 binding;
required GPUBindingResource resource;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBindGroupEntry` | `Gpu.Types.BindGroupEntry` | `browser/gpu/Batches` |

## dictionary `GPUBufferBinding`

```webidl
required GPUBuffer buffer;
GPUSize64 offset = 0;
GPUSize64 size;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferBinding` | `Gpu.Types.BufferBinding` | `browser/gpu/CoverageDescriptors` |

## interface `GPUPipelineLayout`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineLayout` | `Gpu.Handle.PipelineLayout` | `browser/gpu/CoverageDescriptors` |

## includes `GPUPipelineLayout includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.PipelineLayout.label`, `Gpu.PipelineLayout.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUPipelineLayoutDescriptor` `: GPUObjectDescriptorBase`

```webidl
required sequence<GPUBindGroupLayout?> bindGroupLayouts;
GPUSize32 immediateSize = 0;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineLayoutDescriptor` | `Gpu.Types.PipelineLayoutDescriptor` | `browser/gpu/Batches` |

## interface `GPUShaderModule`

```webidl
Promise<GPUCompilationInfo> getCompilationInfo();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUShaderModule` | `Gpu.Handle.Shader` | `browser/gpu/CoverageDescriptors` |
| `getCompilationInfo()` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |

## includes `GPUShaderModule includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Shader.label`, `Gpu.Shader.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUShaderModuleDescriptor` `: GPUObjectDescriptorBase`

```webidl
required USVString code;
sequence<GPUShaderModuleCompilationHint> compilationHints = [];
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUShaderModuleDescriptor` | `Gpu.Types.ShaderModuleDescriptor` | `browser/gpu/Batches` |

## dictionary `GPUShaderModuleCompilationHint`

```webidl
required USVString entryPoint;
(GPUPipelineLayout or GPUAutoLayoutMode) layout;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUShaderModuleCompilationHint` | `Gpu.Types.ShaderModuleCompilationHint` | `browser/gpu/CoverageDescriptors` |

## enum `GPUCompilationMessageType`

`"error"`, `"warning"`, `"info"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCompilationMessageType` | `Gpu.Types.CompilationMessageType` | `browser/gpu/CoverageDescriptors` |

## interface `GPUCompilationMessage`

```webidl
readonly attribute DOMString message;
readonly attribute GPUCompilationMessageType type;
readonly attribute unsigned long long lineNum;
readonly attribute unsigned long long linePos;
readonly attribute unsigned long long offset;
readonly attribute unsigned long long length;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCompilationMessage` | `Gpu.Shader.CompilationMessage` | `browser/gpu/CoverageDescriptors` |
| `message` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |
| `type` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |
| `lineNum` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |
| `linePos` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |
| `offset` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |
| `length` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |

## interface `GPUCompilationInfo`

```webidl
readonly attribute FrozenArray<GPUCompilationMessage> messages;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCompilationInfo` | `Gpu.Shader.CompilationInfo` | `browser/gpu/CoverageDescriptors` |
| `messages` | `Gpu.Shader.getCompilationInfo` | `browser/gpu/CompilationInfoRejected` |

## interface `GPUPipelineError` `: DOMException`

```webidl
constructor(optional DOMString message = "", GPUPipelineErrorInit options);
readonly attribute GPUPipelineErrorReason reason;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineError` | `Gpu.Error.PipelineFailure` | `browser/gpu/CoverageDescriptors` |
| `constructor(message, options)` | `Gpu.Error.PipelineValidation` | `browser/gpu/CoverageDescriptors` |
| `reason` | `Gpu.Error.PipelineValidation`, `Gpu.Error.PipelineInternal` | `browser/gpu/RenderPipelines` |

## dictionary `GPUPipelineErrorInit`

```webidl
required GPUPipelineErrorReason reason;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineErrorInit` | `Gpu.Error.PipelineFailure` | `browser/gpu/CoverageDescriptors` |

## enum `GPUPipelineErrorReason`

`"validation"`, `"internal"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineErrorReason` | `Gpu.Types.PipelineErrorReason` | `browser/gpu/CoverageDescriptors` |

## enum `GPUAutoLayoutMode`

`"auto"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUAutoLayoutMode` | `Gpu.Types.AutoLayoutMode` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUPipelineDescriptorBase` `: GPUObjectDescriptorBase`

```webidl
required (GPUPipelineLayout or GPUAutoLayoutMode) layout;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineDescriptorBase` | `Gpu.Types.PipelineDescriptorBase` | `browser/gpu/CoverageDescriptors` |

## interface mixin `GPUPipelineBase`

```webidl
[NewObject] GPUBindGroupLayout getBindGroupLayout(unsigned long index);
```

Bound on each interface that includes it, below.

## dictionary `GPUProgrammableStage`

```webidl
required GPUShaderModule module;
USVString entryPoint;
record<USVString, GPUPipelineConstantValue> constants = {};
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUProgrammableStage` | `Gpu.Types.ProgrammableStage` | `browser/gpu/Batches` |

## typedef `GPUPipelineConstantValue`

```webidl
typedef double GPUPipelineConstantValue;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPipelineConstantValue` | `Gpu.Scalar.FiniteF64` | `browser/gpu/CanvasPage` |

## interface `GPUComputePipeline`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUComputePipeline` | `Gpu.Handle.ComputePipeline` | `browser/gpu/ComputeCoverage` |

## includes `GPUComputePipeline includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.ComputePipeline.label`, `Gpu.ComputePipeline.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPUComputePipeline includes GPUPipelineBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `getBindGroupLayout(index)` | `Gpu.ComputePipeline.getBindGroupLayout` | `browser/gpu/ComputeCoverage` |

## dictionary `GPUComputePipelineDescriptor` `: GPUPipelineDescriptorBase`

```webidl
required GPUProgrammableStage compute;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUComputePipelineDescriptor` | `Gpu.Types.ComputePipelineDescriptor` | `browser/gpu/Batches` |

## interface `GPURenderPipeline`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPipeline` | `Gpu.Handle.RenderPipeline` | `browser/gpu/RenderBatchDevices` |

## includes `GPURenderPipeline includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.RenderPipeline.label`, `Gpu.RenderPipeline.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPURenderPipeline includes GPUPipelineBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `getBindGroupLayout(index)` | `Gpu.RenderPipeline.getBindGroupLayout` | `browser/gpu/CtsBoundaries` |

## dictionary `GPURenderPipelineDescriptor` `: GPUPipelineDescriptorBase`

```webidl
required GPUVertexState vertex;
GPUPrimitiveState primitive = {};
GPUDepthStencilState depthStencil;
GPUMultisampleState multisample = {};
GPUFragmentState fragment;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPipelineDescriptor` | `Gpu.Types.RenderPipelineDescriptor` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUPrimitiveState`

```webidl
GPUPrimitiveTopology topology = "triangle-list";
GPUIndexFormat stripIndexFormat;
GPUFrontFace frontFace = "ccw";
GPUCullMode cullMode = "none";
boolean unclippedDepth = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPrimitiveState` | `Gpu.Types.PrimitiveState` | `browser/gpu/CoverageDescriptors` |

## enum `GPUPrimitiveTopology`

`"point-list"`, `"line-list"`, `"line-strip"`, `"triangle-list"`, `"triangle-strip"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUPrimitiveTopology` | `Gpu.Types.PrimitiveTopology` | `browser/gpu/CoverageDescriptors` |

## enum `GPUFrontFace`

`"ccw"`, `"cw"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUFrontFace` | `Gpu.Types.FrontFace` | `browser/gpu/CoverageDescriptors` |

## enum `GPUCullMode`

`"none"`, `"front"`, `"back"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCullMode` | `Gpu.Types.CullMode` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUMultisampleState`

```webidl
GPUSize32 count = 1;
GPUSampleMask mask = 0xFFFFFFFF;
boolean alphaToCoverageEnabled = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUMultisampleState` | `Gpu.Types.MultisampleState` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUFragmentState` `: GPUProgrammableStage`

```webidl
required sequence<GPUColorTargetState?> targets;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUFragmentState` | `Gpu.Types.FragmentState` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUColorTargetState`

```webidl
required GPUTextureFormat format;
GPUBlendState blend;
GPUColorWriteFlags writeMask = 0xF;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUColorTargetState` | `Gpu.Types.ColorTargetState` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUBlendState`

```webidl
required GPUBlendComponent color;
required GPUBlendComponent alpha;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBlendState` | `Gpu.Types.BlendState` | `browser/gpu/Conversions` |

## typedef `GPUColorWriteFlags`

```webidl
typedef [EnforceRange] unsigned long GPUColorWriteFlags;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUColorWriteFlags` | `Gpu.Flags.ColorWrites` | `browser/gpu/Conversions` |

## namespace `GPUColorWrite`

```webidl
const GPUFlagsConstant RED = 0x1;
const GPUFlagsConstant GREEN = 0x2;
const GPUFlagsConstant BLUE = 0x4;
const GPUFlagsConstant ALPHA = 0x8;
const GPUFlagsConstant ALL = 0xF;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUColorWrite` | `Gpu.Flags.ColorWrite` | `browser/gpu/Conversions` |

## dictionary `GPUBlendComponent`

```webidl
GPUBlendOperation operation = "add";
GPUBlendFactor srcFactor = "one";
GPUBlendFactor dstFactor = "zero";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBlendComponent` | `Gpu.Types.BlendComponent` | `browser/gpu/Conversions` |

## enum `GPUBlendFactor`

`"zero"`, `"one"`, `"src"`, `"one-minus-src"`, `"src-alpha"`, `"one-minus-src-alpha"`, `"dst"`, `"one-minus-dst"`, `"dst-alpha"`, `"one-minus-dst-alpha"`, `"src-alpha-saturated"`, `"constant"`, `"one-minus-constant"`, `"src1"`, `"one-minus-src1"`, `"src1-alpha"`, `"one-minus-src1-alpha"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBlendFactor` | `Gpu.Types.BlendFactor` | `browser/gpu/CoverageDescriptors` |

## enum `GPUBlendOperation`

`"add"`, `"subtract"`, `"reverse-subtract"`, `"min"`, `"max"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBlendOperation` | `Gpu.Types.BlendOperation` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUDepthStencilState`

```webidl
required GPUTextureFormat format;
boolean depthWriteEnabled;
GPUCompareFunction depthCompare;
GPUStencilFaceState stencilFront = {};
GPUStencilFaceState stencilBack = {};
GPUStencilValue stencilReadMask = 0xFFFFFFFF;
GPUStencilValue stencilWriteMask = 0xFFFFFFFF;
GPUDepthBias depthBias = 0;
float depthBiasSlopeScale = 0;
float depthBiasClamp = 0;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDepthStencilState` | `Gpu.Types.DepthStencilState` | `browser/gpu/RenderPipelines` |

## dictionary `GPUStencilFaceState`

```webidl
GPUCompareFunction compare = "always";
GPUStencilOperation failOp = "keep";
GPUStencilOperation depthFailOp = "keep";
GPUStencilOperation passOp = "keep";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStencilFaceState` | `Gpu.Types.StencilFaceState` | `browser/gpu/RenderScenes` |

## enum `GPUStencilOperation`

`"keep"`, `"zero"`, `"replace"`, `"invert"`, `"increment-clamp"`, `"decrement-clamp"`, `"increment-wrap"`, `"decrement-wrap"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStencilOperation` | `Gpu.Types.StencilOperation` | `browser/gpu/Conversions` |

## enum `GPUIndexFormat`

`"uint16"`, `"uint32"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUIndexFormat` | `Gpu.Types.IndexFormat` | `browser/gpu/CoverageDescriptors` |

## enum `GPUVertexFormat`

`"uint8"`, `"uint8x2"`, `"uint8x4"`, `"sint8"`, `"sint8x2"`, `"sint8x4"`, `"unorm8"`, `"unorm8x2"`, `"unorm8x4"`, `"snorm8"`, `"snorm8x2"`, `"snorm8x4"`, `"uint16"`, `"uint16x2"`, `"uint16x4"`, `"sint16"`, `"sint16x2"`, `"sint16x4"`, `"unorm16"`, `"unorm16x2"`, `"unorm16x4"`, `"snorm16"`, `"snorm16x2"`, `"snorm16x4"`, `"float16"`, `"float16x2"`, `"float16x4"`, `"float32"`, `"float32x2"`, `"float32x3"`, `"float32x4"`, `"uint32"`, `"uint32x2"`, `"uint32x3"`, `"uint32x4"`, `"sint32"`, `"sint32x2"`, `"sint32x3"`, `"sint32x4"`, `"unorm10-10-10-2"`, `"unorm8x4-bgra"`, `"snorm10-10-10-2"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUVertexFormat` | `Gpu.Types.VertexFormat` | `browser/gpu/CoverageDescriptors` |

## enum `GPUVertexStepMode`

`"vertex"`, `"instance"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUVertexStepMode` | `Gpu.Types.VertexStepMode` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUVertexState` `: GPUProgrammableStage`

```webidl
sequence<GPUVertexBufferLayout?> buffers = [];
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUVertexState` | `Gpu.Types.VertexState` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUVertexBufferLayout`

```webidl
required GPUSize64 arrayStride;
GPUVertexStepMode stepMode = "vertex";
required sequence<GPUVertexAttribute> attributes;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUVertexBufferLayout` | `Gpu.Types.VertexBufferLayout` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUVertexAttribute`

```webidl
required GPUVertexFormat format;
required GPUSize64 offset;
required GPUIndex32 shaderLocation;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUVertexAttribute` | `Gpu.Types.VertexAttribute` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUTexelCopyBufferLayout`

```webidl
GPUSize64 offset = 0;
GPUSize32 bytesPerRow;
GPUSize32 rowsPerImage;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTexelCopyBufferLayout` | `Gpu.Types.TexelCopyBufferLayout` | `browser/gpu/Batches` |

## dictionary `GPUTexelCopyBufferInfo` `: GPUTexelCopyBufferLayout`

```webidl
required GPUBuffer buffer;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTexelCopyBufferInfo` | `Gpu.Types.TexelCopyBufferInfo` | `browser/gpu/CanvasPage` |

## dictionary `GPUTexelCopyTextureInfo`

```webidl
required GPUTexture texture;
GPUIntegerCoordinate mipLevel = 0;
GPUOrigin3D origin = {};
GPUTextureAspect aspect = "all";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUTexelCopyTextureInfo` | `Gpu.Types.TexelCopyTextureInfo` | `browser/gpu/Batches` |

## dictionary `GPUCopyExternalImageDestInfo` `: GPUTexelCopyTextureInfo`

```webidl
PredefinedColorSpace colorSpace = "srgb";
boolean premultipliedAlpha = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCopyExternalImageDestInfo` | `Gpu.Types.CopyExternalImageDestInfo` | `browser/gpu/CoverageDescriptors` |

## typedef `GPUCopyExternalImageSource`

```webidl
typedef (ImageBitmap or ImageData or HTMLImageElement or HTMLVideoElement or VideoFrame or HTMLCanvasElement or OffscreenCanvas) GPUCopyExternalImageSource;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCopyExternalImageSource` | `Gpu.Types.CopyExternalImageSource` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUCopyExternalImageSourceInfo`

```webidl
required GPUCopyExternalImageSource source;
GPUOrigin2D origin = {};
boolean flipY = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCopyExternalImageSourceInfo` | `Gpu.Types.CopyExternalImageSourceInfo` | `browser/gpu/CoverageDescriptors` |

## interface `GPUCommandBuffer`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCommandBuffer` | `Gpu.Handle.CommandBuffer` | `browser/gpu/FrameDependencies` |

## includes `GPUCommandBuffer includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.CommandBuffer.label`, `Gpu.CommandBuffer.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUCommandBufferDescriptor` `: GPUObjectDescriptorBase`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCommandBufferDescriptor` | `Gpu.Types.CommandBufferDescriptor` | `browser/gpu/CoverageLabels` |

## interface mixin `GPUCommandsMixin`

No own members; includes/inheritance still apply.

Bound on each interface that includes it, below.

## interface `GPUCommandEncoder`

```webidl
GPURenderPassEncoder beginRenderPass(GPURenderPassDescriptor descriptor);
GPUComputePassEncoder beginComputePass(optional GPUComputePassDescriptor descriptor = {});
undefined copyBufferToBuffer( GPUBuffer source, GPUBuffer destination, optional GPUSize64 size);
undefined copyBufferToBuffer( GPUBuffer source, GPUSize64 sourceOffset, GPUBuffer destination, GPUSize64 destinationOffset, optional GPUSize64 size);
undefined copyBufferToTexture( GPUTexelCopyBufferInfo source, GPUTexelCopyTextureInfo destination, GPUExtent3D copySize);
undefined copyTextureToBuffer( GPUTexelCopyTextureInfo source, GPUTexelCopyBufferInfo destination, GPUExtent3D copySize);
undefined copyTextureToTexture( GPUTexelCopyTextureInfo source, GPUTexelCopyTextureInfo destination, GPUExtent3D copySize);
undefined clearBuffer( GPUBuffer buffer, optional GPUSize64 offset = 0, optional GPUSize64 size);
undefined resolveQuerySet( GPUQuerySet querySet, GPUSize32 firstQuery, GPUSize32 queryCount, GPUBuffer destination, GPUSize64 destinationOffset);
GPUCommandBuffer finish(optional GPUCommandBufferDescriptor descriptor = {});
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCommandEncoder` | `Gpu.Handle.CommandEncoder` | `browser/gpu/CanvasPage` |
| `beginRenderPass(descriptor)` | `Gpu.CommandEncoder.beginRenderPass` | `browser/gpu/CoverageLabels` |
| `beginComputePass(descriptor)` | `Gpu.CommandEncoder.beginComputePass` | `browser/gpu/CoverageLabels` |
| `copyBufferToBuffer(source, destination, size)` | `Gpu.CommandEncoder.copyBuffer` | `browser/gpu/Batches` |
| `copyBufferToBuffer(source, sourceOffset, destination, destinationOffset, size)` | `Gpu.CommandEncoder.copyBufferToBuffer` | `browser/gpu/ComputeDoubles` |
| `copyBufferToTexture(source, destination, copySize)` | `Gpu.CommandEncoder.copyBufferToTexture` | `browser/gpu/ComputeCoverage` |
| `copyTextureToBuffer(source, destination, copySize)` | `Gpu.CommandEncoder.copyTextureToBuffer` | `browser/gpu/CanvasPage` |
| `copyTextureToTexture(source, destination, copySize)` | `Gpu.CommandEncoder.copyTextureToTexture` | `browser/gpu/TextureCopies` |
| `clearBuffer(buffer, offset, size)` | `Gpu.CommandEncoder.clearBuffer` | `browser/gpu/ComputeCoverage` |
| `resolveQuerySet(querySet, firstQuery, queryCount, destination, destinationOffset)` | `Gpu.CommandEncoder.resolveQuerySet` | `browser/gpu/ComputeDoubles` |
| `finish(descriptor)` | `Gpu.CommandEncoder.finish` | `browser/gpu/CoverageLabels` |

## includes `GPUCommandEncoder includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.CommandEncoder.label`, `Gpu.CommandEncoder.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPUCommandEncoder includes GPUCommandsMixin;`

The mixin has no members.

## includes `GPUCommandEncoder includes GPUDebugCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `pushDebugGroup(groupLabel)` | `Gpu.CommandEncoder.pushDebugGroup` | `browser/gpu/EncodeSession` |
| `popDebugGroup()` | `Gpu.CommandEncoder.popDebugGroup` | `browser/gpu/EncodeSession` |
| `insertDebugMarker(markerLabel)` | `Gpu.CommandEncoder.insertDebugMarker` | `browser/gpu/EncodeSession` |

## dictionary `GPUCommandEncoderDescriptor` `: GPUObjectDescriptorBase`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCommandEncoderDescriptor` | `Gpu.Types.CommandEncoderDescriptor` | `browser/gpu/Batches` |

## interface mixin `GPUBindingCommandsMixin`

```webidl
undefined setBindGroup(GPUIndex32 index, GPUBindGroup? bindGroup, optional sequence<GPUBufferDynamicOffset> dynamicOffsets = []);
undefined setBindGroup(GPUIndex32 index, GPUBindGroup? bindGroup, [AllowShared] Uint32Array dynamicOffsetsData, GPUSize64 dynamicOffsetsDataStart, GPUSize32 dynamicOffsetsDataLength);
undefined setImmediates(GPUSize32 rangeOffset, AllowSharedBufferSource data, optional GPUSize64 dataOffset = 0, optional GPUSize64 dataSize);
```

Bound on each interface that includes it, below.

## interface mixin `GPUDebugCommandsMixin`

```webidl
undefined pushDebugGroup(USVString groupLabel);
undefined popDebugGroup();
undefined insertDebugMarker(USVString markerLabel);
```

Bound on each interface that includes it, below.

## interface `GPUComputePassEncoder`

```webidl
undefined setPipeline(GPUComputePipeline pipeline);
undefined dispatchWorkgroups(GPUSize32 workgroupCountX, optional GPUSize32 workgroupCountY = 1, optional GPUSize32 workgroupCountZ = 1);
undefined dispatchWorkgroupsIndirect(GPUBuffer indirectBuffer, GPUSize64 indirectOffset);
undefined end();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUComputePassEncoder` | `Gpu.Handle.ComputePass` | `browser/gpu/ComputeCoverage` |
| `setPipeline(pipeline)` | `Gpu.ComputePass.setPipeline` | `browser/gpu/ComputeCoverage` |
| `dispatchWorkgroups(workgroupCountX, workgroupCountY, workgroupCountZ)` | `Gpu.ComputePass.dispatchWorkgroups` | `browser/gpu/ComputeDoubles` |
| `dispatchWorkgroupsIndirect(indirectBuffer, indirectOffset)` | `Gpu.ComputePass.dispatchWorkgroupsIndirect` | `browser/gpu/ComputeCoverage` |
| `end()` | `Gpu.ComputePass.end` | `browser/gpu/CoverageLabels` |

## includes `GPUComputePassEncoder includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.ComputePass.label`, `Gpu.ComputePass.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPUComputePassEncoder includes GPUCommandsMixin;`

The mixin has no members.

## includes `GPUComputePassEncoder includes GPUDebugCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `pushDebugGroup(groupLabel)` | `Gpu.ComputePass.pushDebugGroup` | `browser/gpu/CoverageLabels` |
| `popDebugGroup()` | `Gpu.ComputePass.popDebugGroup` | `browser/gpu/CoverageLabels` |
| `insertDebugMarker(markerLabel)` | `Gpu.ComputePass.insertDebugMarker` | `browser/gpu/CoverageLabels` |

## includes `GPUComputePassEncoder includes GPUBindingCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `setBindGroup(index, bindGroup, dynamicOffsets)` | `Gpu.ComputePass.setBindGroup` | `browser/gpu/ComputeCoverage` |
| `setBindGroup(index, bindGroup, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength)` | `Gpu.ComputePass.setBindGroupSlice` | `browser/gpu/EncodeSession` |
| `setImmediates(rangeOffset, data, dataOffset, dataSize)` | `Gpu.ComputePass.setImmediates` | `browser/gpu/ComputeCoverage` |

## dictionary `GPUComputePassTimestampWrites`

```webidl
required GPUQuerySet querySet;
GPUSize32 beginningOfPassWriteIndex;
GPUSize32 endOfPassWriteIndex;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUComputePassTimestampWrites` | `Gpu.Types.ComputePassTimestampWrites` | `browser/gpu/ComputeCoverage` |

## dictionary `GPUComputePassDescriptor` `: GPUObjectDescriptorBase`

```webidl
GPUComputePassTimestampWrites timestampWrites;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUComputePassDescriptor` | `Gpu.Types.ComputePassDescriptor` | `browser/gpu/ComputeCoverage` |

## interface `GPURenderPassEncoder`

```webidl
undefined setViewport(float x, float y, float width, float height, float minDepth, float maxDepth);
undefined setScissorRect(GPUIntegerCoordinate x, GPUIntegerCoordinate y, GPUIntegerCoordinate width, GPUIntegerCoordinate height);
undefined setBlendConstant(GPUColor color);
undefined setStencilReference(GPUStencilValue reference);
undefined beginOcclusionQuery(GPUSize32 queryIndex);
undefined endOcclusionQuery();
undefined executeBundles(sequence<GPURenderBundle> bundles);
undefined end();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassEncoder` | `Gpu.Handle.RenderPass` | `browser/gpu/FrameDependencies` |
| `setViewport(x, y, width, height, minDepth, maxDepth)` | `Gpu.RenderPass.setViewport` | `browser/gpu/RenderRefusals` |
| `setScissorRect(x, y, width, height)` | `Gpu.RenderPass.setScissorRect` | `browser/gpu/RenderRefusals` |
| `setBlendConstant(color)` | `Gpu.RenderPass.setBlendConstant` | `browser/gpu/RenderCoverage` |
| `setStencilReference(reference)` | `Gpu.RenderPass.setStencilReference` | `browser/gpu/RenderRefusals` |
| `beginOcclusionQuery(queryIndex)` | `Gpu.RenderPass.beginOcclusionQuery` | `browser/gpu/CtsBoundaries` |
| `endOcclusionQuery()` | `Gpu.RenderPass.endOcclusionQuery` | `browser/gpu/CtsBoundaries` |
| `executeBundles(bundles)` | `Gpu.RenderPass.executeBundles` | `browser/gpu/RenderCoverage` |
| `end()` | `Gpu.RenderPass.end` | `browser/gpu/CoverageLabels` |

## includes `GPURenderPassEncoder includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.RenderPass.label`, `Gpu.RenderPass.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPURenderPassEncoder includes GPUCommandsMixin;`

The mixin has no members.

## includes `GPURenderPassEncoder includes GPUDebugCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `pushDebugGroup(groupLabel)` | `Gpu.RenderPass.pushDebugGroup` | `browser/gpu/RenderRefusals` |
| `popDebugGroup()` | `Gpu.RenderPass.popDebugGroup` | `browser/gpu/RenderRefusals` |
| `insertDebugMarker(markerLabel)` | `Gpu.RenderPass.insertDebugMarker` | `browser/gpu/RenderRefusals` |

## includes `GPURenderPassEncoder includes GPUBindingCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `setBindGroup(index, bindGroup, dynamicOffsets)` | `Gpu.RenderPass.setBindGroup` | `browser/gpu/FrameDependencies` |
| `setBindGroup(index, bindGroup, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength)` | `Gpu.RenderPass.setBindGroupSlice` | `browser/gpu/RenderCoverage` |
| `setImmediates(rangeOffset, data, dataOffset, dataSize)` | `Gpu.RenderPass.setImmediates` | `browser/gpu/RenderRefusals` |

## includes `GPURenderPassEncoder includes GPURenderCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `setPipeline(pipeline)` | `Gpu.RenderPass.setPipeline` | `browser/gpu/RenderCoverage` |
| `setIndexBuffer(buffer, indexFormat, offset, size)` | `Gpu.RenderPass.setIndexBuffer` | `browser/gpu/RenderRefusals` |
| `setVertexBuffer(slot, buffer, offset, size)` | `Gpu.RenderPass.setVertexBuffer` | `browser/gpu/RenderRefusals` |
| `draw(vertexCount, instanceCount, firstVertex, firstInstance)` | `Gpu.RenderPass.draw` | `browser/gpu/RenderCoverage` |
| `drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)` | `Gpu.RenderPass.drawIndexed` | `browser/gpu/RenderRefusals` |
| `drawIndirect(indirectBuffer, indirectOffset)` | `Gpu.RenderPass.drawIndirect` | `browser/gpu/RenderRefusals` |
| `drawIndexedIndirect(indirectBuffer, indirectOffset)` | `Gpu.RenderPass.drawIndexedIndirect` | `browser/gpu/RenderRefusals` |

## dictionary `GPURenderPassTimestampWrites`

```webidl
required GPUQuerySet querySet;
GPUSize32 beginningOfPassWriteIndex;
GPUSize32 endOfPassWriteIndex;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassTimestampWrites` | `Gpu.Types.RenderPassTimestampWrites` | `browser/gpu/RenderCoverage` |

## dictionary `GPURenderPassDescriptor` `: GPUObjectDescriptorBase`

```webidl
required sequence<GPURenderPassColorAttachment?> colorAttachments;
GPURenderPassDepthStencilAttachment depthStencilAttachment;
GPUQuerySet occlusionQuerySet;
GPURenderPassTimestampWrites timestampWrites;
GPUSize64 maxDrawCount = 50000000;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassDescriptor` | `Gpu.Types.RenderPassDescriptor` | `browser/gpu/CanvasPage` |

## dictionary `GPURenderPassColorAttachment`

```webidl
required (GPUTexture or GPUTextureView) view;
GPUIntegerCoordinate depthSlice;
(GPUTexture or GPUTextureView) resolveTarget;
GPUColor clearValue;
required GPULoadOp loadOp;
required GPUStoreOp storeOp;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassColorAttachment` | `Gpu.Types.RenderPassColorAttachment` | `browser/gpu/CanvasPage` |

## dictionary `GPURenderPassDepthStencilAttachment`

```webidl
required (GPUTexture or GPUTextureView) view;
float depthClearValue;
GPULoadOp depthLoadOp;
GPUStoreOp depthStoreOp;
boolean depthReadOnly = false;
GPUStencilValue stencilClearValue = 0;
GPULoadOp stencilLoadOp;
GPUStoreOp stencilStoreOp;
boolean stencilReadOnly = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassDepthStencilAttachment` | `Gpu.Types.RenderPassDepthStencilAttachment` | `browser/gpu/RenderCoverage` |

## enum `GPULoadOp`

`"load"`, `"clear"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPULoadOp` | `Gpu.Types.LoadOp` | `browser/gpu/CanvasPage` |

## enum `GPUStoreOp`

`"store"`, `"discard"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStoreOp` | `Gpu.Types.StoreOp` | `browser/gpu/CanvasPage` |

## dictionary `GPURenderPassLayout` `: GPUObjectDescriptorBase`

```webidl
required sequence<GPUTextureFormat?> colorFormats;
GPUTextureFormat depthStencilFormat;
GPUSize32 sampleCount = 1;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderPassLayout` | `Gpu.Types.RenderPassLayout` | `browser/gpu/Conversions` |

## interface mixin `GPURenderCommandsMixin`

```webidl
undefined setPipeline(GPURenderPipeline pipeline);
undefined setIndexBuffer(GPUBuffer buffer, GPUIndexFormat indexFormat, optional GPUSize64 offset = 0, optional GPUSize64 size);
undefined setVertexBuffer(GPUIndex32 slot, GPUBuffer? buffer, optional GPUSize64 offset = 0, optional GPUSize64 size);
undefined draw(GPUSize32 vertexCount, optional GPUSize32 instanceCount = 1, optional GPUSize32 firstVertex = 0, optional GPUSize32 firstInstance = 0);
undefined drawIndexed(GPUSize32 indexCount, optional GPUSize32 instanceCount = 1, optional GPUSize32 firstIndex = 0, optional GPUSignedOffset32 baseVertex = 0, optional GPUSize32 firstInstance = 0);
undefined drawIndirect(GPUBuffer indirectBuffer, GPUSize64 indirectOffset);
undefined drawIndexedIndirect(GPUBuffer indirectBuffer, GPUSize64 indirectOffset);
```

Bound on each interface that includes it, below.

## interface `GPURenderBundle`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderBundle` | `Gpu.Handle.RenderBundle` | `browser/gpu/CoverageErrors` |

## includes `GPURenderBundle includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.RenderBundle.label`, `Gpu.RenderBundle.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPURenderBundleDescriptor` `: GPUObjectDescriptorBase`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderBundleDescriptor` | `Gpu.Types.RenderBundleDescriptor` | `browser/gpu/CoverageLabels` |

## interface `GPURenderBundleEncoder`

```webidl
GPURenderBundle finish(optional GPURenderBundleDescriptor descriptor = {});
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderBundleEncoder` | `Gpu.Handle.RenderBundleEncoder` | `browser/gpu/CoverageLabels` |
| `finish(descriptor)` | `Gpu.RenderBundleEncoder.finish` | `browser/gpu/CoverageLabels` |

## includes `GPURenderBundleEncoder includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.RenderBundleEncoder.label`, `Gpu.RenderBundleEncoder.setLabel` | `browser/gpu/CoverageLabels` |

## includes `GPURenderBundleEncoder includes GPUCommandsMixin;`

The mixin has no members.

## includes `GPURenderBundleEncoder includes GPUDebugCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `pushDebugGroup(groupLabel)` | `Gpu.RenderBundleEncoder.pushDebugGroup` | `browser/gpu/RenderCoverage` |
| `popDebugGroup()` | `Gpu.RenderBundleEncoder.popDebugGroup` | `browser/gpu/RenderCoverage` |
| `insertDebugMarker(markerLabel)` | `Gpu.RenderBundleEncoder.insertDebugMarker` | `browser/gpu/RenderCoverage` |

## includes `GPURenderBundleEncoder includes GPUBindingCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `setBindGroup(index, bindGroup, dynamicOffsets)` | `Gpu.RenderBundleEncoder.setBindGroup` | `browser/gpu/RenderCoverage` |
| `setBindGroup(index, bindGroup, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength)` | `Gpu.RenderBundleEncoder.setBindGroupSlice` | `browser/gpu/RenderCoverage` |
| `setImmediates(rangeOffset, data, dataOffset, dataSize)` | `Gpu.RenderBundleEncoder.setImmediates` | `browser/gpu/RenderRefusals` |

## includes `GPURenderBundleEncoder includes GPURenderCommandsMixin;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `setPipeline(pipeline)` | `Gpu.RenderBundleEncoder.setPipeline` | `browser/gpu/RenderBatchDevices` |
| `setIndexBuffer(buffer, indexFormat, offset, size)` | `Gpu.RenderBundleEncoder.setIndexBuffer` | `browser/gpu/RenderCoverage` |
| `setVertexBuffer(slot, buffer, offset, size)` | `Gpu.RenderBundleEncoder.setVertexBuffer` | `browser/gpu/RenderCoverage` |
| `draw(vertexCount, instanceCount, firstVertex, firstInstance)` | `Gpu.RenderBundleEncoder.draw` | `browser/gpu/RenderCoverage` |
| `drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)` | `Gpu.RenderBundleEncoder.drawIndexed` | `browser/gpu/RenderCoverage` |
| `drawIndirect(indirectBuffer, indirectOffset)` | `Gpu.RenderBundleEncoder.drawIndirect` | `browser/gpu/RenderCoverage` |
| `drawIndexedIndirect(indirectBuffer, indirectOffset)` | `Gpu.RenderBundleEncoder.drawIndexedIndirect` | `browser/gpu/RenderCoverage` |

## dictionary `GPURenderBundleEncoderDescriptor` `: GPURenderPassLayout`

```webidl
boolean depthReadOnly = false;
boolean stencilReadOnly = false;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPURenderBundleEncoderDescriptor` | `Gpu.Types.RenderBundleEncoderDescriptor` | `browser/gpu/CoverageLabels` |

## dictionary `GPUQueueDescriptor` `: GPUObjectDescriptorBase`

No own members; includes/inheritance still apply.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUQueueDescriptor` | `Gpu.Types.QueueDescriptor` | `browser/gpu/CoverageLabels` |

## interface `GPUQueue`

```webidl
undefined submit(sequence<GPUCommandBuffer> commandBuffers);
Promise<undefined> onSubmittedWorkDone();
undefined writeBuffer( GPUBuffer buffer, GPUSize64 bufferOffset, AllowSharedBufferSource data, optional GPUSize64 dataOffset = 0, optional GPUSize64 size);
undefined writeTexture( GPUTexelCopyTextureInfo destination, AllowSharedBufferSource data, GPUTexelCopyBufferLayout dataLayout, GPUExtent3D size);
undefined copyExternalImageToTexture( GPUCopyExternalImageSourceInfo source, GPUCopyExternalImageDestInfo destination, GPUExtent3D copySize);
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUQueue` | `Gpu.Handle.Queue` | `browser/gpu/FrameOtherQueue` |
| `submit(commandBuffers)` | `Gpu.Queue.submit` | `browser/gpu/ComputeCoverage` |
| `onSubmittedWorkDone()` | `Gpu.Queue.onSubmittedWorkDone` | `browser/gpu/DiagnosticsExemptions` |
| `writeBuffer(buffer, bufferOffset, data, dataOffset, size)` | `Gpu.Queue.writeBuffer` | `browser/gpu/BufferRefusals` |
| `writeTexture(destination, data, dataLayout, size)` | `Gpu.Queue.writeTexture` | `browser/gpu/ComputeCoverage` |
| `copyExternalImageToTexture(source, destination, copySize)` | `Gpu.Queue.copyExternalImageToTexture` | `browser/gpu/CoverageDescriptors` |

## includes `GPUQueue includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.Queue.label`, `Gpu.Queue.setLabel` | `browser/gpu/CoverageLabels` |

## interface `GPUQuerySet`

```webidl
undefined destroy();
readonly attribute GPUQueryType type;
readonly attribute GPUSize32Out count;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUQuerySet` | `Gpu.Handle.QuerySet` | `browser/gpu/ComputeDoubles` |
| `destroy()` | `Gpu.QuerySet.destroy` | `browser/gpu/ComputeCoverage` |
| `type` | `Gpu.QuerySet.type_` | `browser/gpu/CoverageAttributes` |
| `count` | `Gpu.QuerySet.count` | `browser/gpu/CoverageAttributes` |

## includes `GPUQuerySet includes GPUObjectBase;`

| IDL | Declarations | Fixtures |
|---|---|---|
| `label` | `Gpu.QuerySet.label`, `Gpu.QuerySet.setLabel` | `browser/gpu/CoverageLabels` |

## dictionary `GPUQuerySetDescriptor` `: GPUObjectDescriptorBase`

```webidl
required GPUQueryType type;
required GPUSize32 count;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUQuerySetDescriptor` | `Gpu.Types.QuerySetDescriptor` | `browser/gpu/Batches` |

## enum `GPUQueryType`

`"occlusion"`, `"timestamp"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUQueryType` | `Gpu.Types.QueryType` | `browser/gpu/Batches` |

## interface `GPUCanvasContext`

```webidl
readonly attribute (HTMLCanvasElement or OffscreenCanvas) canvas;
undefined configure(GPUCanvasConfiguration configuration);
undefined unconfigure();
GPUCanvasConfiguration? getConfiguration();
GPUTexture getCurrentTexture();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCanvasContext` | `Gpu.Handle.Surface` | `browser/gpu/SurfaceConfiguration` |
| `canvas` | `Gpu.Surface.canvas` | `browser/gpu/SurfaceConfiguration` |
| `configure(configuration)` | `Gpu.Surface.configure` | `browser/gpu/CanvasPage` |
| `unconfigure()` | `Gpu.Surface.unconfigure` | `browser/gpu/DiagnosticsExemptions` |
| `getConfiguration()` | `Gpu.Surface.getConfiguration` | `browser/gpu/CoverageDescriptors` |
| `getCurrentTexture()` | `Gpu.Frame.getCurrentTexture` | `browser/gpu/CanvasPage` |

## enum `GPUCanvasAlphaMode`

`"opaque"`, `"premultiplied"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCanvasAlphaMode` | `Gpu.Types.CanvasAlphaMode` | `browser/gpu/CoverageDescriptors` |

## enum `GPUCanvasToneMappingMode`

`"standard"`, `"extended"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCanvasToneMappingMode` | `Gpu.Types.CanvasToneMappingMode` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUCanvasToneMapping`

```webidl
GPUCanvasToneMappingMode mode = "standard";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCanvasToneMapping` | `Gpu.Types.CanvasToneMapping` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUCanvasConfiguration`

```webidl
required GPUDevice device;
required GPUTextureFormat format;
GPUTextureUsageFlags usage = 0x10;
sequence<GPUTextureFormat> viewFormats = [];
PredefinedColorSpace colorSpace = "srgb";
GPUCanvasToneMapping toneMapping = {};
GPUCanvasAlphaMode alphaMode = "opaque";
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUCanvasConfiguration` | `Gpu.Types.CanvasConfiguration` | `browser/gpu/CanvasPage` |

## enum `GPUDeviceLostReason`

`"unknown"`, `"destroyed"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDeviceLostReason` | `Gpu.Types.DeviceLostReason` | `browser/gpu/CoverageDescriptors` |

## interface `GPUDeviceLostInfo`

```webidl
readonly attribute GPUDeviceLostReason reason;
readonly attribute DOMString message;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDeviceLostInfo` | `Gpu.Error.DeviceLoss` | `browser/gpu/CoverageErrors` |
| `reason` | `Gpu.Error.UnknownLoss`, `Gpu.Error.Destroyed` | `browser/gpu/CoverageErrors`, `browser/gpu/DeviceLoss` |
| `message` | `Gpu.Device.awaitLost` | `browser/gpu/CancelledRequests` |

## partial interface `GPUDevice`

```webidl
readonly attribute Promise<GPUDeviceLostInfo> lost;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `lost` | `Gpu.Device.loss`, `Gpu.Device.awaitLost` | `browser/gpu/CheckedSampler` |

## interface `GPUError`

```webidl
readonly attribute DOMString message;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUError` | `Gpu.Error.GpuError` | `browser/gpu/CoverageErrors` |
| `message` | `Gpu.Diagnostics.popErrorScope` | `browser/gpu/DiagnosticsCancelled` |

## interface `GPUValidationError` `: GPUError`

```webidl
constructor(DOMString message);
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUValidationError` | `Gpu.Error.ValidationError` | `browser/gpu/CoverageErrors`, `browser/gpu/DeviceEventsUncaptured` |
| `constructor(message)` | `Gpu.Error.ValidationError` | `browser/gpu/CoverageErrors` |

## interface `GPUOutOfMemoryError` `: GPUError`

```webidl
constructor(DOMString message);
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUOutOfMemoryError` | `Gpu.Error.OutOfMemoryError` | `browser/gpu/CoverageErrors` |
| `constructor(message)` | `Gpu.Error.OutOfMemoryError` | `browser/gpu/CoverageErrors` |

## interface `GPUInternalError` `: GPUError`

```webidl
constructor(DOMString message);
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUInternalError` | `Gpu.Error.InternalError` | `browser/gpu/CoverageErrors` |
| `constructor(message)` | `Gpu.Error.InternalError` | `browser/gpu/CoverageErrors` |

## enum `GPUErrorFilter`

`"validation"`, `"out-of-memory"`, `"internal"`.

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUErrorFilter` | `Gpu.Types.ErrorFilter` | `browser/gpu/DiagnosticsCallbackThrows` |

## partial interface `GPUDevice`

```webidl
undefined pushErrorScope(GPUErrorFilter filter);
Promise<GPUError?> popErrorScope();
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `pushErrorScope(filter)` | `Gpu.Diagnostics.pushErrorScope` | `browser/gpu/DiagnosticsCallbackThrows` |
| `popErrorScope()` | `Gpu.Diagnostics.popErrorScope` | `browser/gpu/DiagnosticsCancelled` |

## interface `GPUUncapturedErrorEvent` `: Event`

```webidl
constructor( DOMString type, GPUUncapturedErrorEventInit gpuUncapturedErrorEventInitDict );
[SameObject] readonly attribute GPUError error;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUUncapturedErrorEvent` | `Gpu.Error.Uncaptured` | `browser/gpu/DeviceEventsUncaptured` |
| `constructor(type, gpuUncapturedErrorEventInitDict)` | `Gpu.Error.Uncaptured` | `browser/gpu/DeviceEventsUncaptured` |
| `error` | `Gpu.Device.eachEvent` | `browser/gpu/DeviceEvents` |

## dictionary `GPUUncapturedErrorEventInit` `: EventInit`

```webidl
required GPUError error;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUUncapturedErrorEventInit` | `Gpu.Error.Uncaptured` | `browser/gpu/DeviceEventsUncaptured` |

## partial interface `GPUDevice`

```webidl
attribute EventHandler onuncapturederror;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `onuncapturederror` | `Gpu.Device.eachEvent`, `Gpu.Device.onEvent` | `browser/gpu/DeviceEvents`, `browser/gpu/DeviceEventsPage` |

## typedef `GPUBufferDynamicOffset`

```webidl
typedef [EnforceRange] unsigned long GPUBufferDynamicOffset;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUBufferDynamicOffset` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUStencilValue`

```webidl
typedef [EnforceRange] unsigned long GPUStencilValue;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUStencilValue` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUSampleMask`

```webidl
typedef [EnforceRange] unsigned long GPUSampleMask;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSampleMask` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUDepthBias`

```webidl
typedef [EnforceRange] long GPUDepthBias;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUDepthBias` | `Gpu.Scalar.I32` | `browser/gpu/Conversions` |

## typedef `GPUSize64`

```webidl
typedef [EnforceRange] unsigned long long GPUSize64;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSize64` | `Gpu.Scalar.Size64` | `browser/gpu/AdapterAndDevice` |

## typedef `GPUIntegerCoordinate`

```webidl
typedef [EnforceRange] unsigned long GPUIntegerCoordinate;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUIntegerCoordinate` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUIndex32`

```webidl
typedef [EnforceRange] unsigned long GPUIndex32;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUIndex32` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUSize32`

```webidl
typedef [EnforceRange] unsigned long GPUSize32;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSize32` | `Gpu.Scalar.U32` | `browser/gpu/Conversions` |

## typedef `GPUSignedOffset32`

```webidl
typedef [EnforceRange] long GPUSignedOffset32;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSignedOffset32` | `Gpu.Scalar.I32` | `browser/gpu/Conversions` |

## typedef `GPUSize64Out`

```webidl
typedef unsigned long long GPUSize64Out;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSize64Out` | `Gpu.Buffer.size` | `browser/gpu/BufferRoundTrip` |

## typedef `GPUIntegerCoordinateOut`

```webidl
typedef unsigned long GPUIntegerCoordinateOut;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUIntegerCoordinateOut` | `Gpu.Texture.width` | `browser/gpu/CoverageAttributes` |

## typedef `GPUSize32Out`

```webidl
typedef unsigned long GPUSize32Out;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUSize32Out` | `Gpu.Texture.sampleCount` | `browser/gpu/CoverageAttributes` |

## typedef `GPUFlagsConstant`

```webidl
typedef unsigned long GPUFlagsConstant;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUFlagsConstant` | `Gpu.Flags.bufferUsagesBits` | `browser/gpu/Conversions` |

## dictionary `GPUColorDict`

```webidl
required double r;
required double g;
required double b;
required double a;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUColorDict` | `Gpu.Types.ColorDict` | `browser/gpu/CanvasPage` |

## typedef `GPUColor`

```webidl
typedef (sequence<double> or GPUColorDict) GPUColor;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUColor` | `Gpu.Types.Color` | `browser/gpu/RenderCoverage` |

## dictionary `GPUOrigin2DDict`

```webidl
GPUIntegerCoordinate x = 0;
GPUIntegerCoordinate y = 0;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUOrigin2DDict` | `Gpu.Types.Origin2DDict` | `browser/gpu/CoverageDescriptors` |

## typedef `GPUOrigin2D`

```webidl
typedef (sequence<GPUIntegerCoordinate> or GPUOrigin2DDict) GPUOrigin2D;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUOrigin2D` | `Gpu.Types.Origin2D` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUOrigin3DDict`

```webidl
GPUIntegerCoordinate x = 0;
GPUIntegerCoordinate y = 0;
GPUIntegerCoordinate z = 0;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUOrigin3DDict` | `Gpu.Types.Origin3DDict` | `browser/gpu/CoverageDescriptors` |

## typedef `GPUOrigin3D`

```webidl
typedef (sequence<GPUIntegerCoordinate> or GPUOrigin3DDict) GPUOrigin3D;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUOrigin3D` | `Gpu.Types.Origin3D` | `browser/gpu/CoverageDescriptors` |

## dictionary `GPUExtent3DDict`

```webidl
required GPUIntegerCoordinate width;
GPUIntegerCoordinate height = 1;
GPUIntegerCoordinate depthOrArrayLayers = 1;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUExtent3DDict` | `Gpu.Types.Extent3DDict` | `browser/gpu/CoverageDescriptors` |

## typedef `GPUExtent3D`

```webidl
typedef (sequence<GPUIntegerCoordinate> or GPUExtent3DDict) GPUExtent3D;
```

| IDL | Declarations | Fixtures |
|---|---|---|
| `GPUExtent3D` | `Gpu.Types.Extent3D` | `browser/gpu/Batches` |
