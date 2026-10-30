# Structured platform type inventory

All `[Serializable]` or `[Transferable]` interfaces in the pinned WebRef corpus, including proposals. Presence in this list is not an adoption claim. Duplicate FileSystemHandle rows come from distinct specifications.

| Type | Attributes (including exposure/cluster constraints) | Specification |
|---|---|---|
| AudioData | `Exposed=(Window,DedicatedWorker), Serializable, Transferable` | WebCodecs (https://w3c.github.io/webcodecs/) |
| Blob | `Exposed=(Window,Worker), Serializable` | File API (https://w3c.github.io/FileAPI/) |
| CropTarget | `Exposed=(Window,Worker), Serializable` | Region Capture (https://w3c.github.io/mediacapture-region/) |
| CryptoKey | `SecureContext,Exposed=(Window,Worker),Serializable` | Web Cryptography API Level 2 (https://w3c.github.io/webcrypto/) |
| DOMException | `Exposed=*,  Serializable` | Web IDL Standard (https://webidl.spec.whatwg.org/) |
| DOMMatrix | `Exposed=(Window,Worker),  Serializable,  LegacyWindowAlias=(SVGMatrix,WebKitCSSMatrix)` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMMatrixReadOnly | `Exposed=(Window,Worker),  Serializable` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMPoint | `Exposed=(Window,Worker),  Serializable,  LegacyWindowAlias=SVGPoint` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMPointReadOnly | `Exposed=(Window,Worker),  Serializable` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMQuad | `Exposed=(Window,Worker),  Serializable` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMRect | `Exposed=(Window,Worker),  Serializable,  LegacyWindowAlias=SVGRect` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| DOMRectReadOnly | `Exposed=(Window,Worker),  Serializable` | Geometry Interfaces Module Level 1 (https://drafts.csswg.org/geometry-1/) |
| EncodedAudioChunk | `Exposed=(Window,DedicatedWorker), Serializable` | WebCodecs (https://w3c.github.io/webcodecs/) |
| EncodedVideoChunk | `Exposed=(Window,DedicatedWorker), Serializable` | WebCodecs (https://w3c.github.io/webcodecs/) |
| FencedFrameConfig | `Exposed=Window, Serializable` | Fenced Frame (https://wicg.github.io/fenced-frame/) |
| File | `Exposed=(Window,Worker), Serializable` | File API (https://w3c.github.io/FileAPI/) |
| FileList | `Exposed=(Window,Worker), Serializable` | File API (https://w3c.github.io/FileAPI/) |
| FileSystemDirectoryHandle | `Exposed=(Window,Worker), SecureContext, Serializable` | File System Standard (https://fs.spec.whatwg.org/) |
| FileSystemFileHandle | `Exposed=(Window,Worker), SecureContext, Serializable` | File System Standard (https://fs.spec.whatwg.org/) |
| FileSystemHandle | `Exposed=(Window,Worker), SecureContext, Serializable` | File System Access (https://wicg.github.io/file-system-access/) |
| FileSystemHandle | `Exposed=(Window,Worker), SecureContext, Serializable` | File System Standard (https://fs.spec.whatwg.org/) |
| GPUCompilationInfo | `Exposed=(Window, Worker), Serializable, SecureContext` | WebGPU (https://gpuweb.github.io/gpuweb/) |
| GPUCompilationMessage | `Exposed=(Window, Worker), Serializable, SecureContext` | WebGPU (https://gpuweb.github.io/gpuweb/) |
| GPUPipelineError | `Exposed=(Window, Worker), SecureContext, Serializable` | WebGPU (https://gpuweb.github.io/gpuweb/) |
| ImageBitmap | `Exposed=(Window,Worker), Serializable, Transferable` | HTML Standard (https://html.spec.whatwg.org/multipage/) |
| ImageData | `Exposed=(Window,Worker),  Serializable` | HTML Standard (https://html.spec.whatwg.org/multipage/) |
| MIDIAccess | `SecureContext, Exposed=(Window,Worker), Transferable` | Web MIDI API (https://webaudio.github.io/web-midi-api/) |
| MediaSourceHandle | `Transferable, Exposed=(Window,DedicatedWorker)` | Media Source Extensions™ (https://w3c.github.io/media-source/) |
| MediaStreamTrack | `Exposed=(Window,DedicatedWorker), Transferable` | Media Capture and Streams Extensions (https://w3c.github.io/mediacapture-extensions/) |
| MediaStreamTrackHandle | `Exposed=(Window,DedicatedWorker), Transferable` | MediaStreamTrack Insertable Media Processing using Streams (https://w3c.github.io/mediacapture-transform/) |
| MessagePort | `Exposed=(Window,Worker,AudioWorklet), Transferable` | HTML Standard (https://html.spec.whatwg.org/multipage/) |
| OffscreenCanvas | `Exposed=(Window,Worker), Transferable` | HTML Standard (https://html.spec.whatwg.org/multipage/) |
| QuotaExceededError | `Exposed=*, Serializable` | Web IDL Standard (https://webidl.spec.whatwg.org/) |
| RTCCertificate | `Exposed=Window, Serializable` | WebRTC: Real-Time Communication in Browsers (https://w3c.github.io/webrtc-pc/) |
| RTCDataChannel | `Exposed=(Window,DedicatedWorker), Transferable` | WebRTC: Real-Time Communication in Browsers (https://w3c.github.io/webrtc-pc/) |
| RTCEncodedAudioFrame | `Exposed=(Window,DedicatedWorker), Serializable` | WebRTC Encoded Transform (https://w3c.github.io/webrtc-encoded-transform/) |
| RTCEncodedVideoFrame | `Exposed=(Window,DedicatedWorker), Serializable` | WebRTC Encoded Transform (https://w3c.github.io/webrtc-encoded-transform/) |
| ReadableStream | `Exposed=*, Transferable` | Streams Standard (https://streams.spec.whatwg.org/) |
| RestrictionTarget | `Exposed=(Window,Worker), Serializable` | Element Capture (https://screen-share.github.io/element-capture/) |
| TransformStream | `Exposed=*, Transferable` | Streams Standard (https://streams.spec.whatwg.org/) |
| VideoFrame | `Exposed=(Window,DedicatedWorker), Serializable, Transferable` | WebCodecs (https://w3c.github.io/webcodecs/) |
| WebTransportDatagramsWritable | `Exposed=(Window,Worker), SecureContext, Transferable` | WebTransport (https://w3c.github.io/webtransport/) |
| WebTransportError | `Exposed=(Window,Worker), Serializable, SecureContext` | WebTransport (https://w3c.github.io/webtransport/) |
| WebTransportReceiveStream | `Exposed=(Window,Worker), SecureContext, Transferable` | WebTransport (https://w3c.github.io/webtransport/) |
| WebTransportSendStream | `Exposed=(Window,Worker), SecureContext, Transferable` | WebTransport (https://w3c.github.io/webtransport/) |
| WritableStream | `Exposed=*, Transferable` | Streams Standard (https://streams.spec.whatwg.org/) |
