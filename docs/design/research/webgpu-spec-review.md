# Independent review of the WebGPU proposal against the specification

**2026-10-29.** Reviewed proposal commit
[`5678c99ce`](https://github.com/canassa/beni/commit/5678c99ce) in
[PR #1262](https://github.com/canassa/beni/pull/1262), at the owner's request.
This report records a read-only review: it does not revise or adopt the
proposal, and does not claim runtime implementation or conformance.

The native API inventory is comprehensive. Resolve the two adapter gaps below
before adopting the API, and make the two additional failure predicates
explicit. Two further contracts need decisions but are not proven specification
contradictions. All six findings have separate tracking issues.

## 1. P1 — Expose the Mapping produced by mappedAtCreation

Tracking: [#1266](https://github.com/canassa/beni/issues/1266).
Evidence: [creation signature](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L241),
[mapping signatures](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L565),
and [mapped-at-creation prose](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L583).

`createBuffer` returns only `Buffer`, while `getMappedRange` requires `Mapping`.
The declared producer of `Mapping` is `Buffer.map`, corresponding to native
`mapAsync`. The native operation rejects when the buffer is already mapped.
[WebGPU buffer mapping](https://www.w3.org/TR/2026/CRD-webgpu-20260915/#dom-gpubuffer-mapasync).

The prose correctly says `mappedAtCreation` produces a mapping handle, but no
public signature explains how the caller obtains it. This is a missing
producer, not a contradiction in the prose about native behavior. With the
declared signatures, an application cannot initialize its mapped-at-creation
vertex or uniform buffer.

Return a buffer plus optional mapping, add a `currentMapping` accessor, or
provide a dedicated mapped constructor. Define the corresponding route for
Batch and diagnostic creation as well.

## 2. P2 — Define synchronous resource operations inside Frame

Tracking: [#1267](https://github.com/canassa/beni/issues/1267).
Evidence: [Frame signatures](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L615)
and [same-task contract](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L630).

`Frame.importExternalTexture` returns an external texture, but Frame has no
declared `createBindGroup` operation or conversion to Batch authority. The
ordinary checked `Device.createBindGroup` can suspend and therefore cannot run
inside the Frame's sync callback. A newly imported video texture must be bound
before drawing in the task where it remains usable.
[WebGPU external texture import](https://www.w3.org/TR/2026/CRD-webgpu-20260915/#dom-gpudevice-importexternaltexture).

Batch promises synchronous forwarding for every native synchronous operation,
so the foundation has another possible route. This finding concerns the Frame
adapter's typing, not an omitted native declaration. Expose Frame's Batch/session
authority, or specify systematic synchronous forwarding for bind-group creation,
texture views, writes and other required resource operations.

## 3. P2 — Explicitly require fixed-length backing for GPU binary inputs

Tracking: [#1268](https://github.com/canassa/beni/issues/1268).
Evidence: [binary-input ledger row](https://github.com/canassa/beni/blob/5678c99ce/docs/design/research/webgpu-errors.md#L97)
and [Binary contract](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L166).

Web IDL rejects resizable ArrayBuffer and growable SharedArrayBuffer backing
unless `AllowResizable` is present, including backing that has never resized
and views that are currently in bounds. Neither `AllowSharedBufferSource` nor
the GPU binding command's Uint32Array overload grants that attribute.
[Buffer-source conversion](https://webidl.spec.whatwg.org/#es-buffer-source-types),
[AllowSharedBufferSource](https://webidl.spec.whatwg.org/#AllowSharedBufferSource).

The proposal mentions detachment, resizing and bounds checks, but does not name
this independent restriction. General preflight wording could accommodate the
correct implementation; it does not mandate misclassification. The supporting
Binary contract is also explicitly unfinished. This is a required refinement,
not evidence of an existing runtime defect.

Specify a named input error and fixed-length-backing preflight for ordinary and
shared sources and views. Require acceptance cases for never-resized resizable
backing as well as resized, detached and out-of-bounds sources.

## 4. P2 — Separate mapped size alignment from allocation RangeError

Tracking: [#1269](https://github.com/canassa/beni/issues/1269).
Evidence: [createBuffer ledger row](https://github.com/canassa/beni/blob/5678c99ce/docs/design/research/webgpu-errors.md#L74).

`createBuffer` with `mappedAtCreation = true` throws RangeError when size is not
divisible by four, before allocating mapped storage. The ledger names the
allocation RangeError but omits this other documented cause.
[WebGPU buffer creation](https://www.w3.org/TR/2026/CRD-webgpu-20260915/#dom-gpudevice-createbuffer).

Generic descriptor/alignment preflight can already cover it, so this is an
omitted explicit predicate rather than proof that every implementation would
mislabel it as allocation failure. Require that alignment preflight explicitly;
classify a residual RangeError as mapped allocation failure only after it
passes. Require separate malformed-size and backing-allocation acceptance cases.

## 5. Open contract — Diagnostic lease reentrancy

Tracking: [#1270](https://github.com/canassa/beni/issues/1270).
Evidence: [lease rules](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L523)
and [explicit session forwarding](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L539).

Ordinary operations wait while a diagnostic session owns the device, and are
explicitly not implicitly associated with the session. Define what happens
when the session callback invokes an ordinary checked operation on the same
device: under the literal waiting rule it waits for its own lease.

Choose a typed same-owner refusal or an explicit reentrant route. Include
cleanup/destruction, nested sessions, child-fiber joins, cancellation and
cross-device acquisition. This is an unresolved beni concurrency contract,
not a claim that WebGPU mandates a particular lease implementation.

## 6. Open contract — Empty and multiple-submit receipts

Tracking: [#1271](https://github.com/canassa/beni/issues/1271).
Evidence: [Frame result signature](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L615)
and [zero/multiple-submit behavior](https://github.com/canassa/beni/blob/5678c99ce/docs/design/webgpu.md#L640).

Frame always returns `Submission`, while permitting zero or multiple submits.
An opaque receipt could represent an empty aggregate, an existing boundary,
or the final boundary, so this is not inherently impossible. Define which
meaning applies and when its native completion fence is captured.

Native `onSubmittedWorkDone` covers work submitted before its invocation. A
later fence can include unrelated submissions unless the receipt contract
accounts for that. [WebGPU queue completion](https://www.w3.org/TR/2026/CRD-webgpu-20260915/#dom-gpuqueue-onsubmittedworkdone).

## 7. What was verified, and limits

The independent review compared the published WebGPU draft, pinned editor
source and committed IDL snapshot; reproduced the vendored extraction; checked
all 18 cached source hashes; and ran the offline inventory check. No native
declaration omission was found. The three-filter scope model, distinction
between defined device-loss/internal failures and defects, and acknowledgement
of unobservable WGSL errors agree with the inspected specification.

The review covered the proposal, ledger, research, complete IDL surface, relevant
WebGPU algorithms, imported Web IDL rules and WGSL error semantics. It did not
run browsers or CTS, prove every WGSL builtin, or validate performance. There
is no implemented runtime in this PR to exercise. The supporting source
collection and its caveats remain in [webgpu/README.md](webgpu/README.md).
