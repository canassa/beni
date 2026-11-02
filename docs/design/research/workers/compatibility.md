# Browser compatibility snapshot

Extracted from MDN BCD 8.1.7. This is recorded compatibility data, not a browser test.
Every conditional/version range/flag/note is retained in [compat.json](compat.json); `true` means supported but no version recorded, `false` means unsupported, `null` means unknown. Desktop columns below do not imply mobile support.

| Feature | Chromium | Firefox | Safari |
|---|---|---|---|
| AudioData | 94 | 130 | 26 |
| AudioData.AudioData | 94 | 130 | 26 |
| AudioData.allocationSize | 94 | 130 | 26 |
| AudioData.clone | 94 | 130 | 26 |
| AudioData.close | 94 | 130 | 26 |
| AudioData.copyTo | 94 | 130 | 26 |
| AudioData.duration | 94 | 130 | 26 |
| AudioData.format | 94 | 130 | 26 |
| AudioData.numberOfChannels | 94 | 130 | 26 |
| AudioData.numberOfFrames | 94 | 130 | 26 |
| AudioData.sampleRate | 94 | 130 | 26 |
| AudioData.timestamp | 94 | 130 | 26 |
| Blob | 5 | 4 | 6 |
| Blob.Blob | 20 | 13 (notes) | 6 |
| Blob.arrayBuffer | 76 | 69 | 14 |
| Blob.bytes | 144 | 128 | 18 |
| Blob.size | 5 | 4 | 6 |
| Blob.slice | 21; 5–25 | 13 (notes); 5–13 | 7; 6–7 |
| Blob.stream | 76 | 69 | 14.1 |
| Blob.text | 76 | 69 | 14 |
| Blob.textStream | 151 | False | False |
| Blob.type | 5 | 4 | 6 |
| BroadcastChannel | 54 | 38 | 15.4 |
| BroadcastChannel.BroadcastChannel | 54 | 38 | 15.4 |
| BroadcastChannel.close | 54 | 38 | 15.4 |
| BroadcastChannel.message_event | 54 | 38 | 15.4 |
| BroadcastChannel.messageerror_event | 60 | 57 | 15.4 |
| BroadcastChannel.name | 54 | 38 | 15.4 |
| BroadcastChannel.postMessage | 54 | 38 | 15.4 |
| CropTarget | 104 | False | False |
| CropTarget.fromElement_static | 104 | False | False |
| CryptoKey | 37 | 34 | 10 |
| CryptoKey.algorithm | 37 | 34 | 10 |
| CryptoKey.extractable | 37 | 34 | 10 |
| CryptoKey.type | 37 | 34 | 10 |
| CryptoKey.usages | 37 | 34 | 10 |
| DOMException | 1 | 1 | 1 |
| DOMException.DOMException | 46 | 37 | 10.1 |
| DOMException.code | 1 | 1 | 1 |
| DOMException.message | 1 | 1 | 1 |
| DOMException.name | 1 | 1 | 1 |
| DOMException.serializable_object | 77 | 101 | False |
| DOMMatrix | 61; 5; 2 | 33; 49; 1.5 | 11; 5; 4 |
| DOMMatrix.DOMMatrix | 61; 5; 2 | 33; 49; 1.5 | 11; 5; 4 |
| DOMMatrix.a | 61 | 33 | 11 |
| DOMMatrix.b | 61 | 33 | 11 |
| DOMMatrix.c | 61 | 33 | 11 |
| DOMMatrix.d | 61 | 33 | 11 |
| DOMMatrix.e | 61 | 33 | 11 |
| DOMMatrix.f | 61 | 33 | 11 |
| DOMMatrix.fromFloat32Array_static | 61 | 69 | 11 |
| DOMMatrix.fromFloat64Array_static | 61 | 69 | 11 |
| DOMMatrix.fromMatrix_static | 61 | 69 | 11 |
| DOMMatrix.invertSelf | 61 | 33 | 11 |
| DOMMatrix.m11 | 61 | 33 | 11 |
| DOMMatrix.m12 | 61 | 33 | 11 |
| DOMMatrix.m13 | 61 | 33 | 11 |
| DOMMatrix.m14 | 61 | 33 | 11 |
| DOMMatrix.m21 | 61 | 33 | 11 |
| DOMMatrix.m22 | 61 | 33 | 11 |
| DOMMatrix.m23 | 61 | 33 | 11 |
| DOMMatrix.m24 | 61 | 33 | 11 |
| DOMMatrix.m31 | 61 | 33 | 11 |
| DOMMatrix.m32 | 61 | 33 | 11 |
| DOMMatrix.m33 | 61 | 33 | 11 |
| DOMMatrix.m34 | 61 | 33 | 11 |
| DOMMatrix.m41 | 61 | 33 | 11 |
| DOMMatrix.m42 | 61 | 33 | 11 |
| DOMMatrix.m43 | 61 | 33 | 11 |
| DOMMatrix.m44 | 61 | 33 | 11 |
| DOMMatrix.multiplySelf | 61 | 33 | 11 |
| DOMMatrix.preMultiplySelf | 61 | 33 | 11 |
| DOMMatrix.rotateAxisAngleSelf | 61 | 33 | 11 |
| DOMMatrix.rotateFromVectorSelf | 61 | 33 | 11 |
| DOMMatrix.rotateSelf | 61 | 33 | 11 |
| DOMMatrix.scale3dSelf | 61 | 33 (notes) | 11 |
| DOMMatrix.scaleSelf | 61 | 33 (notes) | 11 |
| DOMMatrix.setMatrixValue | 61 | 33 | 11 |
| DOMMatrix.skewXSelf | 61 | 33 | 11 |
| DOMMatrix.skewYSelf | 61 | 33 | 11 |
| DOMMatrix.translateSelf | 61 | 33 | 11 |
| DOMMatrix.worker_support | 61 | 69 | 11 |
| DOMMatrixReadOnly | 61 | 33 | 11 |
| DOMMatrixReadOnly.DOMMatrixReadOnly | 61 | 62 | 11 |
| DOMMatrixReadOnly.a | 61 | 33 | 11 |
| DOMMatrixReadOnly.b | 61 | 33 | 11 |
| DOMMatrixReadOnly.c | 61 | 33 | 11 |
| DOMMatrixReadOnly.d | 61 | 33 | 11 |
| DOMMatrixReadOnly.e | 61 | 33 | 11 |
| DOMMatrixReadOnly.f | 61 | 33 | 11 |
| DOMMatrixReadOnly.flipX | 61 | 33 | 11 |
| DOMMatrixReadOnly.flipY | 61 | 33 | 11 |
| DOMMatrixReadOnly.fromFloat32Array_static | 61 | 69 | 11 |
| DOMMatrixReadOnly.fromFloat64Array_static | 61 | 69 | 11 |
| DOMMatrixReadOnly.fromMatrix_static | 61 | 69 | 11 |
| DOMMatrixReadOnly.inverse | 61 | 33 | 11 |
| DOMMatrixReadOnly.is2D | 61 | 33 | 11 |
| DOMMatrixReadOnly.isIdentity | 61 | 59 | 11 |
| DOMMatrixReadOnly.m11 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m12 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m13 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m14 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m21 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m22 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m23 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m24 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m31 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m32 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m33 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m34 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m41 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m42 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m43 | 61 | 33 | 11 |
| DOMMatrixReadOnly.m44 | 61 | 33 | 11 |
| DOMMatrixReadOnly.multiply | 61 | 33 | 11 |
| DOMMatrixReadOnly.rotate | 61 | 33 | 11 |
| DOMMatrixReadOnly.rotateAxisAngle | 61 | 33 | 11 |
| DOMMatrixReadOnly.rotateFromVector | 61 | 33 | 11 |
| DOMMatrixReadOnly.scale | 61 | 33 (notes) | 11 |
| DOMMatrixReadOnly.scale3d | 61 | 33 (notes) | 11 |
| DOMMatrixReadOnly.scaleNonUniform | 73 | 33 | 17.4 |
| DOMMatrixReadOnly.skewX | 61 | 33 (notes) | 11 |
| DOMMatrixReadOnly.skewY | 61 | 33 (notes) | 11 |
| DOMMatrixReadOnly.toFloat32Array | 61 | 33 | 11 |
| DOMMatrixReadOnly.toFloat64Array | 61 | 33 | 11 |
| DOMMatrixReadOnly.toJSON | 61 | 62 | 11 |
| DOMMatrixReadOnly.toString | 61 | 33 | 11 |
| DOMMatrixReadOnly.transformPoint | 61 | 33 | 11 |
| DOMMatrixReadOnly.translate | 61 | 33 | 11 |
| DOMMatrixReadOnly.worker_support | 61 | 69 | 11 |
| DOMPoint | 61 | 31 | 10.1 |
| DOMPoint.DOMPoint | 61 | 31 | 10.1 |
| DOMPoint.fromPoint_static | 61 | 62 | 10.1 |
| DOMPoint.w | 61 | 31 | 10.1 |
| DOMPoint.worker_support | 61 | 69 | 10.1 |
| DOMPoint.x | 61 | 31 | 10.1 |
| DOMPoint.y | 61 | 31 | 10.1 |
| DOMPoint.z | 61 | 31 | 10.1 |
| DOMPointReadOnly | 61 | 31 | 10.1 |
| DOMPointReadOnly.DOMPointReadOnly | 61 | 62 | 10.1 |
| DOMPointReadOnly.fromPoint_static | 61 | 62 | 10.1 |
| DOMPointReadOnly.matrixTransform | 61 | 69 | 11 |
| DOMPointReadOnly.toJSON | 61 | 62 | 10.1 |
| DOMPointReadOnly.w | 61 | 31 | 10.1 |
| DOMPointReadOnly.worker_support | 61 | 69 | 10.1 |
| DOMPointReadOnly.x | 61 | 31 | 10.1 |
| DOMPointReadOnly.y | 61 | 31 | 10.1 |
| DOMPointReadOnly.z | 61 | 31 | 10.1 |
| DOMQuad | 61 | 31 | 11 |
| DOMQuad.DOMQuad | 61 | 31 | 11 |
| DOMQuad.fromQuad_static | 61 | 69 | 11 |
| DOMQuad.fromRect_static | 61 | 69 | 11 |
| DOMQuad.getBounds | 61 | 62 | 11 |
| DOMQuad.p1 | 61 | 31 (notes) | 11 |
| DOMQuad.p2 | 61 | 31 (notes) | 11 |
| DOMQuad.p3 | 61 | 31 (notes) | 11 |
| DOMQuad.p4 | 61 | 31 (notes) | 11 |
| DOMQuad.toJSON | 61 | 62 | 11 |
| DOMQuad.worker_support | 61 | 69 | 11 |
| DOMRect | 61; 2–61 | 27; 3–27 | 10.1; 4–11 |
| DOMRect.DOMRect | 61 | 31 | 10.1 |
| DOMRect.fromRect_static | 61 | 69 | 10.1 |
| DOMRect.height | 2 | 3 | 4 |
| DOMRect.width | 2 | 3 | 4 |
| DOMRect.worker_support | 61 | 69 | 10.1 |
| DOMRect.x | 61 | 31 | 10.1 |
| DOMRect.y | 61 | 31 | 10.1 |
| DOMRectReadOnly | 61; 2–61 | 31; 27–31; 3–27 | 10.1; 4–11 |
| DOMRectReadOnly.DOMRectReadOnly | 61 | 62 | 10.1 |
| DOMRectReadOnly.bottom | 2 | 3 | 4 |
| DOMRectReadOnly.fromRect_static | 61 | 69 | 10.1 |
| DOMRectReadOnly.height | 2 | 3 | 4 |
| DOMRectReadOnly.left | 2 | 3 | 4 |
| DOMRectReadOnly.right | 2 | 3 | 4 |
| DOMRectReadOnly.toJSON | 61 | 62 | 10.1 |
| DOMRectReadOnly.top | 2 | 3 | 4 |
| DOMRectReadOnly.width | 2 | 3 | 4 |
| DOMRectReadOnly.worker_support | 61 | 69 | 10.1 |
| DOMRectReadOnly.x | 61 | 31 | 10.1 |
| DOMRectReadOnly.y | 61 | 31 | 10.1 |
| DedicatedWorkerGlobalScope | 4 | 3.5 | 4 |
| DedicatedWorkerGlobalScope.cancelAnimationFrame | 69 | 99 | 16.4 |
| DedicatedWorkerGlobalScope.close | 4 | 3.5 | 4 |
| DedicatedWorkerGlobalScope.message_event | 4 | 3.5 | 4 |
| DedicatedWorkerGlobalScope.messageerror_event | 60 | 57 | 16.4 |
| DedicatedWorkerGlobalScope.name | 70 | 55 | 12.1 |
| DedicatedWorkerGlobalScope.postMessage | 4 | 3.5 | 4 |
| DedicatedWorkerGlobalScope.requestAnimationFrame | 69 (notes) | 99 | 16.4 |
| DedicatedWorkerGlobalScope.rtctransform_event | 141 | 117 | 15.4 |
| EncodedAudioChunk | 94 | 130 | 26 |
| EncodedAudioChunk.EncodedAudioChunk | 94 | 130 | 26 |
| EncodedAudioChunk.byteLength | 94 | 130 | 26 |
| EncodedAudioChunk.copyTo | 94 | 130 | 26 |
| EncodedAudioChunk.duration | 94 | 130 | 26 |
| EncodedAudioChunk.timestamp | 94 | 130 | 26 |
| EncodedAudioChunk.type | 94 | 130 | 26 |
| EncodedVideoChunk | 94 | 130 | 16.4 |
| EncodedVideoChunk.EncodedVideoChunk | 94 | 130 | 16.4 |
| EncodedVideoChunk.byteLength | 94 | 130 | 16.4 |
| EncodedVideoChunk.copyTo | 94 | 130 | 16.4 |
| EncodedVideoChunk.duration | 94 | 130 | 16.4 |
| EncodedVideoChunk.timestamp | 94 | 130 | 16.4 |
| EncodedVideoChunk.type | 94 | 130 | 16.4 |
| FencedFrameConfig | 126 | False | False |
| FencedFrameConfig.setSharedStorageContext | 126–154 | False | False |
| File | 13 | 7; 3–7 (notes) | 4 |
| File.File | 38 | 28 | 10.1 |
| File.lastModified | 13 | 15 | 10 |
| File.lastModifiedDate | 13 | 15–61 | 7–10 |
| File.name | 13 | 3.6 | 8 |
| File.webkitRelativePath | 13 | 50 | 11.1 |
| FileList | 2 | 3 | 4 |
| FileList.item | 2 | 3 | 4 |
| FileList.length | 2 | 3 | 4 |
| FileSystemDirectoryHandle | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.@@asyncIterator | 86 | 111 | 16.4 |
| FileSystemDirectoryHandle.entries | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.getDirectoryHandle | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.getFileHandle | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.keys | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.removeEntry | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.resolve | 86 | 111 | 15.2 |
| FileSystemDirectoryHandle.values | 86 | 111 | 15.2 |
| FileSystemFileHandle | 86 | 111 | 15.2 |
| FileSystemFileHandle.createSyncAccessHandle | 102 | 111 | 15.2 |
| FileSystemFileHandle.createSyncAccessHandle.mode | 121 | False | False |
| FileSystemFileHandle.createWritable | 86 | 111 | 26 |
| FileSystemFileHandle.createWritable.mode | 121 | False | False |
| FileSystemFileHandle.getFile | 86 | 111 | 15.2 |
| FileSystemHandle | 86 | 111 | 15.2 |
| FileSystemHandle.isSameEntry | 86 | 111 | 15.2 |
| FileSystemHandle.kind | 86 | 111 | 15.2 |
| FileSystemHandle.move | 102 (partial) (notes) | 111 | 15.2 |
| FileSystemHandle.name | 86 | 111 | 15.2 |
| FileSystemHandle.queryPermission | 86 | False | False |
| FileSystemHandle.remove | 110 | False | False |
| FileSystemHandle.requestPermission | 86 | False | False |
| GPUCompilationInfo | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationInfo.messages | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.length | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.lineNum | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.linePos | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.message | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.offset | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUCompilationMessage.type | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUPipelineError | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUPipelineError.GPUPipelineError | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUPipelineError.GPUPipelineError.message_optional | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| GPUPipelineError.reason | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| ImageBitmap | 50 | 42 | 15 |
| ImageBitmap.close | 52 | 46 | 15 |
| ImageBitmap.height | 50 | 42 | 15 |
| ImageBitmap.width | 50 | 42 | 15 |
| ImageData | 1 | 3.5 | 3.1 |
| ImageData.ImageData | 36 | 29 | 8 |
| ImageData.ImageData.settings_parameter | 92 | False | 15.2 |
| ImageData.ImageData.settings_parameter.colorSpace_option | 92 | False | 15.2 |
| ImageData.ImageData.settings_parameter.pixelFormat_option | 137 | False | False |
| ImageData.colorSpace | 92 | False | 15.2 |
| ImageData.data | 1 | 3.5 | 3.1 |
| ImageData.height | 1 | 3.5 | 3.1 |
| ImageData.pixelFormat | 137 | False | False |
| ImageData.width | 1 | 3.5 | 3.1 |
| ImageData.worker_support | 36 | 25 | 7 |
| MIDIAccess | 43 | 108 | False |
| MIDIAccess.inputs | 43 | 108 | False |
| MIDIAccess.outputs | 43 | 108 | False |
| MIDIAccess.statechange_event | 43 | 108 (partial) (notes) | False |
| MIDIAccess.sysexEnabled | 43 | 108 | False |
| MediaSourceHandle | 108 | False | 18 |
| MediaStreamTrack | 26 | 22 | 11 |
| MediaStreamTrack.applyConstraints | 59 | 43 | 11 |
| MediaStreamTrack.applyConstraints.aspectRatio_constraint | 59 | False | 11 |
| MediaStreamTrack.applyConstraints.autoGainControl_constraint | 67 | 55; 46 | False |
| MediaStreamTrack.applyConstraints.channelCount_constraint | 59 | False | False |
| MediaStreamTrack.applyConstraints.deviceId_constraint | 59 | 43 (notes) | 11 |
| MediaStreamTrack.applyConstraints.displaySurface_constraint | 107 | False | 11.1 |
| MediaStreamTrack.applyConstraints.echoCancellation_constraint | 59 | 50 | 11 |
| MediaStreamTrack.applyConstraints.echoCancellation_constraint.all | 141 | False | False |
| MediaStreamTrack.applyConstraints.echoCancellation_constraint.remote-only | 141 | False | False |
| MediaStreamTrack.applyConstraints.facingMode_constraint | 59 | 50 | 11 |
| MediaStreamTrack.applyConstraints.frameRate_constraint | 59 | 50 | 11 |
| MediaStreamTrack.applyConstraints.groupId_constraint | 59 | 70 | 11 |
| MediaStreamTrack.applyConstraints.height_constraint | 59 | 50 | 11 |
| MediaStreamTrack.applyConstraints.latency_constraint | 59 | 50 | False |
| MediaStreamTrack.applyConstraints.logicalSurface_constraint | False | False | 11.1 |
| MediaStreamTrack.applyConstraints.noiseSuppression_constraint | 67 | 55; 46 | False |
| MediaStreamTrack.applyConstraints.resizeMode_constraint | 72 | 144 | False |
| MediaStreamTrack.applyConstraints.restrictOwnAudio_constraint | 141 | False | False |
| MediaStreamTrack.applyConstraints.sampleRate_constraint | 59 | False | 11 |
| MediaStreamTrack.applyConstraints.sampleSize_constraint | 59 | False | 11 |
| MediaStreamTrack.applyConstraints.suppressLocalAudioPlayback_constraint | 109 | False | False |
| MediaStreamTrack.applyConstraints.volume_constraint | 59 | False | 11 |
| MediaStreamTrack.applyConstraints.width_constraint | 59 | 50 | 11 |
| MediaStreamTrack.capturehandlechange_event | 102 | False | False |
| MediaStreamTrack.clone | 35 | 48 | 11 |
| MediaStreamTrack.configurationchange_event | False | False | 16.4 |
| MediaStreamTrack.contentHint | 70 | False | 12.1 |
| MediaStreamTrack.enabled | 26 | 24 | 11 |
| MediaStreamTrack.ended_event | 26 | 50 | 11 |
| MediaStreamTrack.getCapabilities | 59 | 132 | 11 |
| MediaStreamTrack.getCaptureHandle | 102 | False | False |
| MediaStreamTrack.getConstraints | 53 | 50 | 11 |
| MediaStreamTrack.getSettings | 59 | 50 | 11 |
| MediaStreamTrack.getSettings.return_object_property_screenPixelRatio | 136 | False | False |
| MediaStreamTrack.id | 26 | 22 | 11 |
| MediaStreamTrack.kind | 26 | 22 | 11 |
| MediaStreamTrack.label | 26 | 22 | 11 |
| MediaStreamTrack.mute_event | 26 | 59 | 11 |
| MediaStreamTrack.muted | 38 | 59 (partial) (notes) | 11 |
| MediaStreamTrack.readyState | 26 | 50 | 11 |
| MediaStreamTrack.stats | 120 | False | False |
| MediaStreamTrack.stop | 32 | 34 | 11 |
| MediaStreamTrack.unmute_event | 26 | 59 | 11 |
| MediaStreamTrackHandle | False | False | preview |
| MediaStreamTrackHandle.MediaStreamTrackHandle | False | False | preview |
| MessageChannel | 2 | 41 | 5 |
| MessageChannel.MessageChannel | 2 | 41 | 5 |
| MessageChannel.port1 | 2 | 41 | 5 |
| MessageChannel.port2 | 2 | 41 | 5 |
| MessagePort | 2 | 41 | 5 |
| MessagePort.close | 2 | 41 | 5 |
| MessagePort.message_event | 2 | 41 | 5 |
| MessagePort.messageerror_event | 60 | 57 | 16.4 |
| MessagePort.postMessage | 2 | 41 | 5 |
| MessagePort.postMessage.options_includeUserActivation_parameter | 72 | False | False |
| MessagePort.start | 2 | 41 | 5 |
| MessagePort.worker_support | 4 | 41 | 5 |
| OffscreenCanvas | 69 | 105 | 16.4 |
| OffscreenCanvas.OffscreenCanvas | 69 | 105 | 16.4 |
| OffscreenCanvas.clearElementGeometry | 157 | False | False |
| OffscreenCanvas.contextlost_event | 99 | 125 | False |
| OffscreenCanvas.contextrestored_event | 99 | 125 | False |
| OffscreenCanvas.convertToBlob | 69 | 105; 105 | 16.4 |
| OffscreenCanvas.convertToBlob.option_type_parameter_webp | 69 | 105 | False |
| OffscreenCanvas.getContext | 69 | 105 | 16.4 |
| OffscreenCanvas.getContext.2d_context | 69 | 105 | 16.4 |
| OffscreenCanvas.getContext.bitmaprenderer_context | 76 | 105 | 16.4 |
| OffscreenCanvas.getContext.webgl2_context | 69 | 105 | 17 |
| OffscreenCanvas.getContext.webgl_context | 69 | 105 | 17 |
| OffscreenCanvas.getContext.webgpu_context | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| OffscreenCanvas.getElementImageDefaultSize | 157 | False | False |
| OffscreenCanvas.height | 69 | 105 | 16.4 |
| OffscreenCanvas.transferToImageBitmap | 69 | 105 | 16.4 |
| OffscreenCanvas.updateElementGeometry | 157 | False | False |
| OffscreenCanvas.width | 69 | 105 | 16.4 |
| QuotaExceededError | 138 | False | preview |
| QuotaExceededError.QuotaExceededError | 138 | False | preview |
| QuotaExceededError.quota | 138 | False | preview |
| QuotaExceededError.requested | 138 | False | preview |
| RTCCertificate | 49 | 42 | 12.1 |
| RTCCertificate.expires | 49 | 42 | 12.1 |
| RTCCertificate.getFingerprints | 61 | 138 | 12.1 |
| RTCDataChannel | 24 | 22 | 11 |
| RTCDataChannel.binaryType | 24 | 22 | 11 |
| RTCDataChannel.binaryType.arraybuffer_value | 24 | 22 | 11 |
| RTCDataChannel.binaryType.blob_value | 129 | 22 | 11 |
| RTCDataChannel.bufferedAmount | 24 | 22 | 11 |
| RTCDataChannel.bufferedAmountLowThreshold | 46 | 44 | 11 |
| RTCDataChannel.bufferedamountlow_event | 57 (notes) | 44 | 11 |
| RTCDataChannel.close | 24 | 22 | 11 |
| RTCDataChannel.close_event | 24 | 22 | 11 |
| RTCDataChannel.closing_event | 81 | 144 | 15.4 |
| RTCDataChannel.error_event | 24 | 22 | 11 |
| RTCDataChannel.id | 30 | 22 | 11 |
| RTCDataChannel.label | 24 | 22 | 11 |
| RTCDataChannel.maxPacketLifeTime | 56 | 62 | 11 |
| RTCDataChannel.maxRetransmits | 30 | 62 | 11 |
| RTCDataChannel.message_event | 24 | 22 | 11 |
| RTCDataChannel.negotiated | 30 | 68 | 11 |
| RTCDataChannel.open_event | 24 | 22 | 11 |
| RTCDataChannel.ordered | 30 | 22 | 11 |
| RTCDataChannel.priority | False | False | 15 |
| RTCDataChannel.protocol | 30 | 22 | 11 |
| RTCDataChannel.readyState | 24 | 22 | 11 |
| RTCDataChannel.reliable | 24 | 22–142 | False |
| RTCDataChannel.sctp_sdp_21 | 58 | 63 | False |
| RTCDataChannel.send | 24 | 22 | 11 |
| RTCDataChannel.transferable | 130 | 144 | 15 |
| RTCEncodedAudioFrame | 86 | 117 | 15.4 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame | 127 | 145 | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_audioLevel_parameter | 127 | False | False |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_captureTime_parameter | 127 | False | False |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_contributingSources_parameter | 127 | 145 | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_mimeType_parameter | 127 | False | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_payloadType_parameter | 127 | 145 | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_receiveTime_parameter | 127 | 152 | False |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_rtpTimestamp_parameter | 127 | 145 | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_sequenceNumber_parameter | 127 | 145 | 26 |
| RTCEncodedAudioFrame.RTCEncodedAudioFrame.options_metadata_synchronizationSource_parameter | 127 | 145 | 26 |
| RTCEncodedAudioFrame.data | 86 | 117 | 15.4 |
| RTCEncodedAudioFrame.getMetadata | 86 | 117 | 15.4 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_audioLevel | 139 | False | False |
| RTCEncodedAudioFrame.getMetadata.return_object_property_captureTime | 127 | False | False |
| RTCEncodedAudioFrame.getMetadata.return_object_property_contributingSources | 127 | 145 | 26 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_mimeType | 127 | False | 26 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_payloadType | 127 | 145 | 26 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_receiveTime | 127 | 152 | False |
| RTCEncodedAudioFrame.getMetadata.return_object_property_rtpTimestamp | 127 | 145 | 26 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_sequenceNumber | 127 | 145 | 26 |
| RTCEncodedAudioFrame.getMetadata.return_object_property_synchronizationSource | 127 | 145 | 26 |
| RTCEncodedAudioFrame.timestamp | 86 | 117 | 15.4 |
| RTCEncodedVideoFrame | 86 | 117 | 15.4 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_contributingSources_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_dependencies_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_frameId_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_height_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_mimeType_parameter | 127 | False | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_payloadType_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_receiveTime_parameter | 127 | 152 | False |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_rtpTimestamp_parameter | 127 | False | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_spatialIndex_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_synchronizationSource_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_temporalIndex_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.RTCEncodedVideoFrame.options_metadata_width_parameter | 127 | 145 | 26 |
| RTCEncodedVideoFrame.data | 86 | 117 | 15.4 |
| RTCEncodedVideoFrame.getMetadata | 86 | 117 | 15.4 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_contributingSources | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_dependencies | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_frameId | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_height | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_mimeType | 127 | False | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_payloadType | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_receiveTime | 127 | 152 | False |
| RTCEncodedVideoFrame.getMetadata.return_object_property_rtpTimestamp | 127 | False | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_spatialIndex | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_synchronizationSource | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_temporalIndex | 127 | 145 | 26 |
| RTCEncodedVideoFrame.getMetadata.return_object_property_width | 127 | 145 | 26 |
| RTCEncodedVideoFrame.timestamp | 86 | 117 | 15.4 |
| RTCEncodedVideoFrame.type | 86 | 117 | 15.4 |
| ReadableStream | 43 | 65 | 10.1 |
| ReadableStream.@@asyncIterator | 124 | 110 | 27 |
| ReadableStream.ReadableStream | 52 | 65 | 10.1 |
| ReadableStream.cancel | 43 | 65 | 10.1 |
| ReadableStream.from_static | False | 117 | 27 |
| ReadableStream.getReader | 43 | 65 | 10.1 |
| ReadableStream.locked | 52 | 65 | 10.1 |
| ReadableStream.pipeThrough | 59 | 102 | 10.1 |
| ReadableStream.pipeTo | 59 | 100 | 10.1 |
| ReadableStream.tee | 52 | 65 | 10.1 |
| ReadableStream.transferable | 87 | 103 | 27 |
| ReadableStream.values | 124 | 110 | 27 |
| RestrictionTarget | 132 | False | False |
| RestrictionTarget.fromElement_static | 132 | False | False |
| ServiceWorker | 40 | 44 | 11.1 |
| ServiceWorker.ecmascript_modules | 91 | 147 | 15 (notes) |
| ServiceWorker.error_event | 40 | 44 | 11.1 |
| ServiceWorker.postMessage | 40 | 44 | 11.1 |
| ServiceWorker.scriptURL | 40 | 44 | 11.1 |
| ServiceWorker.state | 40 | 44 | 11.1 |
| ServiceWorker.statechange_event | 40 | 44 | 11.1 |
| ServiceWorkerContainer | 40 | 44 | 11.1 |
| ServiceWorkerContainer.controller | 40 | 44 | 11.1 |
| ServiceWorkerContainer.controllerchange_event | 40 | 44 | 11.1 |
| ServiceWorkerContainer.getRegistration | 40 | 44 | 11.1 |
| ServiceWorkerContainer.getRegistrations | 45 | 44 | 11.1 |
| ServiceWorkerContainer.message_event | 40 | 44 | 11.1 |
| ServiceWorkerContainer.messageerror_event | 80 | 65 | 16.4; 11.1–16.4 (partial) (notes) |
| ServiceWorkerContainer.ready | 40 | 44 | 11.1 |
| ServiceWorkerContainer.register | 40 | 44 | 11.1 |
| ServiceWorkerContainer.register.enforces_trusted_types | 140 | preview | 26 |
| ServiceWorkerContainer.startMessages | 74 | 64 | 11.1 |
| ServiceWorkerContainer.worker_support | False | 133 | 11.1 |
| ServiceWorkerGlobalScope | 40 | 44 | 11.1 |
| ServiceWorkerGlobalScope.abortpayment_event | 70 | False | False |
| ServiceWorkerGlobalScope.activate_event | 40 | 44 | 11.1 |
| ServiceWorkerGlobalScope.backgroundfetchabort_event | 74 | False | False |
| ServiceWorkerGlobalScope.backgroundfetchclick_event | 74 | False | False |
| ServiceWorkerGlobalScope.backgroundfetchfail_event | 74 | False | False |
| ServiceWorkerGlobalScope.backgroundfetchsuccess_event | 74 | False | False |
| ServiceWorkerGlobalScope.canmakepayment_event | 70 | False | False |
| ServiceWorkerGlobalScope.clients | 40 | 44 | 11.1 |
| ServiceWorkerGlobalScope.contentdelete_event | False | False | False |
| ServiceWorkerGlobalScope.cookieStore | 87 | 140 | 18.4 |
| ServiceWorkerGlobalScope.cookiechange_event | 87 | 140 | False |
| ServiceWorkerGlobalScope.fetch_event | 40 | 44 | 11.1 |
| ServiceWorkerGlobalScope.install_event | 40 | 44 (notes) | 11.1 (notes) |
| ServiceWorkerGlobalScope.message_event | 40 | 44 | 11.1 |
| ServiceWorkerGlobalScope.messageerror_event | 81 | 65 | 11.1 (partial) (notes) |
| ServiceWorkerGlobalScope.notificationclick_event | 40 | 44 | 16 (notes) |
| ServiceWorkerGlobalScope.notificationclose_event | 50 | 44 | 16 (notes) |
| ServiceWorkerGlobalScope.paymentrequest_event | 70 | False | False |
| ServiceWorkerGlobalScope.periodicsync_event | 80 | False | False |
| ServiceWorkerGlobalScope.push_event | 40 | 44 | 16 (notes) |
| ServiceWorkerGlobalScope.pushsubscriptionchange_event | 138 | 44 (partial) (notes) | 16 (notes) |
| ServiceWorkerGlobalScope.registration | 42 | 44 | 11.1 |
| ServiceWorkerGlobalScope.serviceWorker | 79 | False | 15.4 |
| ServiceWorkerGlobalScope.skipWaiting | 41 | 44 | 11.1 |
| ServiceWorkerGlobalScope.sync_event | 49 | False | False |
| ServiceWorkerRegistration | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.active | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.backgroundFetch | 74 | False | False |
| ServiceWorkerRegistration.cookies | 87 | 140 | False |
| ServiceWorkerRegistration.getNotifications | 40 | 44 | 16 (notes) |
| ServiceWorkerRegistration.index | False | False | False |
| ServiceWorkerRegistration.installing | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.navigationPreload | 59 | 99 | 15.4 |
| ServiceWorkerRegistration.paymentManager | 70 | False | False |
| ServiceWorkerRegistration.periodicSync | 80 | False | False |
| ServiceWorkerRegistration.pushManager | 40 | 44 | 16 (notes) |
| ServiceWorkerRegistration.scope | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.showNotification | 42 | 44 | 16 (notes) |
| ServiceWorkerRegistration.showNotification.options_actions_parameter | 48 | 152 | False |
| ServiceWorkerRegistration.showNotification.options_badge_parameter | 53 | False | False |
| ServiceWorkerRegistration.showNotification.options_data_parameter | 44 | False | False |
| ServiceWorkerRegistration.showNotification.options_image_parameter | 56 | False | False |
| ServiceWorkerRegistration.showNotification.options_navigate_parameter | False | 158 | 18.5 |
| ServiceWorkerRegistration.showNotification.options_renotify_parameter | 50 | False | False |
| ServiceWorkerRegistration.showNotification.options_requireInteraction_parameter | 47 | False | False |
| ServiceWorkerRegistration.showNotification.options_vibrate_parameter | 45 | False | False |
| ServiceWorkerRegistration.sync | 49 | False | False |
| ServiceWorkerRegistration.unregister | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.update | 45 (notes) | 44 | 11.1 |
| ServiceWorkerRegistration.updateViaCache | 68 | 57 | 11.1 |
| ServiceWorkerRegistration.updatefound_event | 40 | 44 | 11.1 |
| ServiceWorkerRegistration.waiting | 40 | 44 | 11.1 |
| SharedWorker | 5 | 29 | 16; 5–7 |
| SharedWorker.SharedWorker | 5 | 29 | 16; 5–7 |
| SharedWorker.SharedWorker.ecmascript_modules | 80 | 114 | 15 (notes) |
| SharedWorker.SharedWorker.enforces_trusted_types | 97 | preview | 26 |
| SharedWorker.SharedWorker.mime_checks | False | 81 | 16 |
| SharedWorker.SharedWorker.options_extendedLifetime_parameter | 148 | False | False |
| SharedWorker.SharedWorker.options_name_parameter | 70 | 55 | False |
| SharedWorker.SharedWorker.options_sameSiteCookies_parameter | 125 | False | False |
| SharedWorker.SharedWorker.options_type_parameter | 80 | 114 | 15 |
| SharedWorker.error_event | 5 | 29 | 16; 5–7 |
| SharedWorker.port | 5 | 29 | 16; 5–7 |
| SharedWorkerGlobalScope | 4 | 29 | 16; 5–7 |
| SharedWorkerGlobalScope.close | 4 | 29 | 16; 5–7 |
| SharedWorkerGlobalScope.connect_event | 4 | 29 (notes) | 16; 5–7 |
| SharedWorkerGlobalScope.name | 4 | 29 | 16; 5–7 |
| TransformStream | 67 | 102 | 14.1 |
| TransformStream.TransformStream | 67 | 102 | 14.1 |
| TransformStream.TransformStream.transformer_cancel | False | False | False |
| TransformStream.readable | 67 | 102 | 14.1 |
| TransformStream.transferable | 87 | 103 | False |
| TransformStream.writable | 67 | 102 | 14.1 |
| VideoFrame | 94 | 130 | 16.4 |
| VideoFrame.VideoFrame | 94 | 130 | 16.4 |
| VideoFrame.VideoFrame.flip_option | 138 | False | False |
| VideoFrame.VideoFrame.metadata_option | 145 | False | False |
| VideoFrame.VideoFrame.rotation_option | 138 | False | False |
| VideoFrame.allocationSize | 94 | 130 | 16.4 |
| VideoFrame.clone | 94 | 130 | 16.4 |
| VideoFrame.close | 94 | 130 | 16.4 |
| VideoFrame.codedHeight | 94 | 130 | 16.4 |
| VideoFrame.codedRect | 94 | 130 | 16.4 |
| VideoFrame.codedWidth | 94 | 130 | 16.4 |
| VideoFrame.colorSpace | 94 | 130 | 16.4 |
| VideoFrame.copyTo | 94 | 130 | 16.4 |
| VideoFrame.copyTo.format_property | 127 | 130 | False |
| VideoFrame.displayHeight | 94 | 130 | 16.4 |
| VideoFrame.displayWidth | 94 | 130 | 16.4 |
| VideoFrame.duration | 94 | 130 | 16.4 |
| VideoFrame.flip | 138 | False | False |
| VideoFrame.format | 94 | 130 | 16.4 |
| VideoFrame.metadata | 145 | False | False |
| VideoFrame.rotation | 138 | False | False |
| VideoFrame.timestamp | 94 | 130 | 16.4 |
| VideoFrame.visibleRect | 94 | 130 | 16.4 |
| WebTransportDatagramsWritable | False | 155 | 26.4 |
| WebTransportDatagramsWritable.sendGroup | False | 155 | 26.4 |
| WebTransportDatagramsWritable.sendOrder | False | 155 | 26.4 |
| WebTransportError | 97 | 114 | 26.4 |
| WebTransportError.WebTransportError | 97 | 114 | 26.4 |
| WebTransportError.source | 97 | 114 | 26.4 |
| WebTransportError.streamErrorCode | 97 | 114 | 26.4 |
| WebTransportReceiveStream | False | 114 | 26.4 |
| WebTransportReceiveStream.getStats | False | 114 | 26.4 |
| WebTransportSendStream | False | 114 | 26.4 |
| WebTransportSendStream.getStats | False | 114 | 26.4 |
| WebTransportSendStream.getWriter | False | 114 | 26.4 |
| WebTransportSendStream.sendGroup | False | 155 | 26.4 |
| WebTransportSendStream.sendOrder | False | 121 | 26.4 |
| Worker | 2 | 3.5 | 4 |
| Worker.Worker | 4 | 3.5 | 4 |
| Worker.Worker.ecmascript_modules | 80 | 114 | 15 (notes) |
| Worker.Worker.enforces_trusted_types | 97 | preview | 26 |
| Worker.Worker.mime_checks | False | 81 | 16 |
| Worker.Worker.options_name_parameter | 70 | 55 | 12.1 |
| Worker.Worker.options_type_parameter | 80 | 114 | 15 |
| Worker.error_event | 4 | 3.5 | 4 |
| Worker.message_event | 4 | 3.5 | 4 |
| Worker.messageerror_event | False | 57 | 16.4 |
| Worker.postMessage | 2 | 3.5 | 4 |
| Worker.postMessage.options_includeUserActivation_parameter | 72 | False | False |
| Worker.terminate | 2 | 3.5 | 4 |
| Worker.worker_support | 69 (partial) (notes) | 34 | 16.4 (partial) (notes) |
| WorkerGlobalScope | 4 | 3.5 | 4 |
| WorkerGlobalScope.dump | False | 3.5 (partial) (notes) | False |
| WorkerGlobalScope.error_event | 4 | 3.5 | 4 |
| WorkerGlobalScope.fonts | 69 | 105 | 15 |
| WorkerGlobalScope.importScripts | 4 | 4 | 4 |
| WorkerGlobalScope.importScripts.enforces_trusted_types | 138 | preview | 26 |
| WorkerGlobalScope.importScripts.mime_checks | 71 | 67 | 16 |
| WorkerGlobalScope.languagechange_event | 4 | 74 | False |
| WorkerGlobalScope.location | 4 | 3.5 | 4 |
| WorkerGlobalScope.navigator | 4 | 3.5 | 4 |
| WorkerGlobalScope.offline_event | False | 29 | 8 |
| WorkerGlobalScope.online_event | False | 29 | 8 |
| WorkerGlobalScope.rejectionhandled_event | 49 | 69 | 11 |
| WorkerGlobalScope.securitypolicyviolation_event | 41 | 63 | 10 |
| WorkerGlobalScope.self | 4 | 3.5 | 4 |
| WorkerGlobalScope.unhandledrejection_event | 49 | 69 | 11 |
| WorkerLocation | 4 | 3.5 | 4 |
| WorkerLocation.hash | 4 | 3.5 | 4 |
| WorkerLocation.host | 4 | 3.5 | 4 |
| WorkerLocation.hostname | 4 | 3.5 | 4 |
| WorkerLocation.href | 4 | 3.5 | 4 |
| WorkerLocation.origin | 38 | 29 | 10 |
| WorkerLocation.pathname | 4 | 3.5 | 4 |
| WorkerLocation.port | 4 | 3.5 | 4 |
| WorkerLocation.protocol | 4 | 3.5 | 4 |
| WorkerLocation.search | 4 | 3.5 | 4 |
| WorkerLocation.toString | 4 | 3.5 | 4 |
| WorkerNavigator | 4 | 3.5 | 4 |
| WorkerNavigator.appCodeName | 4 | 3.5 | 10 |
| WorkerNavigator.appName | 4 | 3.5 | 4 |
| WorkerNavigator.appVersion | 4 | 3.5 | 4 |
| WorkerNavigator.connection | 61 | False | False |
| WorkerNavigator.deviceMemory | 65 (notes) | False | False |
| WorkerNavigator.globalPrivacyControl | False | 120 (notes) | False |
| WorkerNavigator.gpu | 144 (notes); 113–144 (partial) (notes) | 141 (partial) (notes) | 26 |
| WorkerNavigator.hardwareConcurrency | 37 | 48 | 15.4 (notes); 10.1–11 |
| WorkerNavigator.hid | 131 | False | False |
| WorkerNavigator.language | 4 | 3.5 (notes) | 10 |
| WorkerNavigator.languages | 37 (notes) | 32 (notes) | 10.1 |
| WorkerNavigator.locks | 69 | 96 | 15.4 |
| WorkerNavigator.mediaCapabilities | 76 | 63 | 15.4 |
| WorkerNavigator.ml | 112 (flag) | False | False |
| WorkerNavigator.onLine | 4 | 3.5 (notes) | 4 |
| WorkerNavigator.permissions | 43 | 133 | 16.4 |
| WorkerNavigator.platform | 4 | 3.5 (notes) | 4 |
| WorkerNavigator.product | 4 | 3.5 | 10 |
| WorkerNavigator.serial | 89 | 151 | False |
| WorkerNavigator.serviceWorker | False | 133 | 11.1 |
| WorkerNavigator.storage | 55 | 57 | 15.2 |
| WorkerNavigator.storageBuckets | 122 | False | False |
| WorkerNavigator.usb | 118 (partial) (notes); 70–118 (partial) (notes) | False | False |
| WorkerNavigator.userAgent | 4 | 3.5 | 4 |
| WorkerNavigator.userAgentData | 90 | False | False |
| WritableStream | 59 | 100 | 14.1 |
| WritableStream.WritableStream | 59 | 100 | 14.1 |
| WritableStream.abort | 59 | 100 | 14.1 |
| WritableStream.close | 81 | 100 | 14.1 |
| WritableStream.getWriter | 59 | 100 | 14.1 |
| WritableStream.locked | 59 | 100 | 14.1 |
| WritableStream.transferable | 87 | 103 | False |
| javascript.ArrayBuffer | 7 | 4 | 5.1 |
| javascript.ArrayBuffer.@@species | 51 | 48 | 10 |
| javascript.ArrayBuffer.ArrayBuffer | 7 | 4 | 5.1 |
| javascript.ArrayBuffer.ArrayBuffer.maxByteLength_option | 111 | 128 | 16.4 |
| javascript.ArrayBuffer.byteLength | 7 | 4 | 5.1 |
| javascript.ArrayBuffer.detached | 114 | 122 | 17.4 |
| javascript.ArrayBuffer.isView | 32 | 29 | 7 |
| javascript.ArrayBuffer.maxByteLength | 111 | 128 | 16.4 |
| javascript.ArrayBuffer.resizable | 111 | 128 | 16.4 |
| javascript.ArrayBuffer.resize | 111 | 128 | 16.4 |
| javascript.ArrayBuffer.slice | 17 | 12 (notes) | 5.1 |
| javascript.ArrayBuffer.transfer | 114 | 122 | 17.4 |
| javascript.ArrayBuffer.transferToFixedLength | 114 | 122 | 17.4 |
| javascript.SharedArrayBuffer | 68 | 79 | 15.2 |
| javascript.SharedArrayBuffer.@@species | 68 | 79 | 15.2 |
| javascript.SharedArrayBuffer.SharedArrayBuffer | 68 | 79 | 15.2 |
| javascript.SharedArrayBuffer.SharedArrayBuffer.maxByteLength_option | 111 | 128 | 16.4 |
| javascript.SharedArrayBuffer.byteLength | 68 | 79 | 15.2 |
| javascript.SharedArrayBuffer.grow | 111 | 128 | 16.4 |
| javascript.SharedArrayBuffer.growable | 111 | 128 | 16.4 |
| javascript.SharedArrayBuffer.maxByteLength | 111 | 128 | 16.4 |
| javascript.SharedArrayBuffer.slice | 68 | 79 | 15.2 |
| javascript.Atomics | 68 | 78 | 15.2 (notes) |
| javascript.Atomics.Atomic_operations_on_non_shared_buffers | False | 79 | False |
| javascript.Atomics.add | 68 | 78 | 15.2 |
| javascript.Atomics.and | 68 | 78 | 15.2 |
| javascript.Atomics.compareExchange | 68 | 78 | 15.2 |
| javascript.Atomics.exchange | 68 | 78 | 15.2 |
| javascript.Atomics.isLockFree | 68 | 78 | 15.2 |
| javascript.Atomics.load | 68 | 78 | 15.2 |
| javascript.Atomics.notify | 68 | 78 | 15.2 |
| javascript.Atomics.or | 68 | 78 | 15.2 |
| javascript.Atomics.pause | 133 | 137 | 18.4 |
| javascript.Atomics.store | 68 | 78 | 15.2 |
| javascript.Atomics.sub | 68 | 78 | 15.2 |
| javascript.Atomics.wait | 68 | 78 | 15.2 |
| javascript.Atomics.waitAsync | 90; 87–90 (partial) (notes) | 145 | 16.4 |
| javascript.Atomics.xor | 68 | 78 | 15.2 |
| javascript.DataView | 9 | 15 | 5.1 |
| javascript.DataView.DataView | 9 | 15 | 5.1 |
| javascript.DataView.DataView.sharedarraybuffer_support | 68 | 79 | 15.2 |
| javascript.DataView.buffer | 9 | 15 | 5.1 |
| javascript.DataView.byteLength | 9 | 15 | 5.1 |
| javascript.DataView.byteOffset | 9 | 15 | 5.1 |
| javascript.DataView.getBigInt64 | 67 | 68 | 15 |
| javascript.DataView.getBigUint64 | 67 | 68 | 15 |
| javascript.DataView.getFloat16 | 135 | 129 | 18.2 |
| javascript.DataView.getFloat32 | 9 | 15 | 5.1 |
| javascript.DataView.getFloat64 | 9 | 15 | 5.1 |
| javascript.DataView.getInt16 | 9 | 15 | 5.1 |
| javascript.DataView.getInt32 | 9 | 15 | 5.1 |
| javascript.DataView.getInt8 | 9 | 15 | 5.1 |
| javascript.DataView.getUint16 | 9 | 15 | 5.1 |
| javascript.DataView.getUint32 | 9 | 15 | 5.1 |
| javascript.DataView.getUint8 | 9 | 15 | 5.1 |
| javascript.DataView.setBigInt64 | 67 | 68 | 15 |
| javascript.DataView.setBigUint64 | 67 | 68 | 15 |
| javascript.DataView.setFloat16 | 135 | 129 | 18.2 |
| javascript.DataView.setFloat32 | 9 | 15 | 5.1 |
| javascript.DataView.setFloat64 | 9 | 15 | 5.1 |
| javascript.DataView.setInt16 | 9 | 15 | 5.1 |
| javascript.DataView.setInt32 | 9 | 15 | 5.1 |
| javascript.DataView.setInt8 | 9 | 15 | 5.1 |
| javascript.DataView.setUint16 | 9 | 15 | 5.1 |
| javascript.DataView.setUint32 | 9 | 15 | 5.1 |
| javascript.DataView.setUint8 | 9 | 15 | 5.1 |
| javascript.TypedArray | 7 | 4 | 5.1 |
| javascript.TypedArray.@@iterator | 38 | 36; 27–36 (notes); 17–27 (notes) | 10 |
| javascript.TypedArray.@@species | 51 | 48 | 10 |
| javascript.TypedArray.BYTES_PER_ELEMENT | 7 | 4 | 5.1 |
| javascript.TypedArray.at | 92 | 90 | 15.4 |
| javascript.TypedArray.buffer | 7 | 4 | 5.1 |
| javascript.TypedArray.byteLength | 7 | 4 | 5.1 |
| javascript.TypedArray.byteOffset | 7 | 4 | 5.1 |
| javascript.TypedArray.constructor_without_parameters | 7 | 55 | 5.1 |
| javascript.TypedArray.copyWithin | 45 | 34 | 10 |
| javascript.TypedArray.entries | 45 | 37 | 10 |
| javascript.TypedArray.every | 45 | 37 | 10 |
| javascript.TypedArray.fill | 45 | 37 | 10 |
| javascript.TypedArray.filter | 45 | 38 | 10 |
| javascript.TypedArray.find | 45 | 37 | 10 |
| javascript.TypedArray.findIndex | 45 | 37 | 10 |
| javascript.TypedArray.findLast | 97 | 104 | 15.4 |
| javascript.TypedArray.findLastIndex | 97 | 104 | 15.4 |
| javascript.TypedArray.forEach | 45 | 38 | 10 |
| javascript.TypedArray.from | 45 | 38 | 10 |
| javascript.TypedArray.includes | 47 | 43 | 10 |
| javascript.TypedArray.indexOf | 45 | 37 (notes) | 10 |
| javascript.TypedArray.index_properties_not_consulting_prototype | 7 (notes) | 25 | 5.1 (notes) |
| javascript.TypedArray.iterable_in_constructor | 39 | 52 | 10 |
| javascript.TypedArray.join | 45 | 37 | 10 |
| javascript.TypedArray.keys | 38 | 37 | 10 |
| javascript.TypedArray.lastIndexOf | 45 | 37 (notes) | 10 |
| javascript.TypedArray.length | 7 | 4 | 5.1 |
| javascript.TypedArray.map | 45 | 38 | 10 |
| javascript.TypedArray.name | 7 | 4 | 5.1 |
| javascript.TypedArray.named_properties | 7 | 30 | 5.1 |
| javascript.TypedArray.of | 45 | 38 | 10 |
| javascript.TypedArray.reduce | 45 | 37 | 10 |
| javascript.TypedArray.reduceRight | 45 | 37 | 10 |
| javascript.TypedArray.reverse | 45 | 37 | 10 |
| javascript.TypedArray.set | 7 | 4 | 5.1 |
| javascript.TypedArray.slice | 45 | 38 | 10 |
| javascript.TypedArray.some | 45 | 37 | 10 |
| javascript.TypedArray.sort | 45 | 46 | 10 |
| javascript.TypedArray.subarray | 7 | 4 | 5.1 |
| javascript.TypedArray.toLocaleString | 7 | 51 | 5.1 |
| javascript.TypedArray.toReversed | 110 | 115 | 16 |
| javascript.TypedArray.toSorted | 110 | 115 | 16 |
| javascript.TypedArray.toString | 7 | 51 | 5.1 |
| javascript.TypedArray.values | 38 | 37 | 10 |
| javascript.TypedArray.with | 110 | 115 | 16 |
| webassembly.api.Module | 57 | 52 | 11 |
| webassembly.api.Module.Module | 57 | 52 | 11 |
| webassembly.api.Module.Module.compile_options | 130 | 134 | False |
| webassembly.api.Module.customSections_static | 57 | 52 | 11 |
| webassembly.api.Module.exports_static | 57 | 52 | 11 |
| webassembly.api.Module.imports_static | 57 | 52 | 11 |
| webassembly.threads-and-atomics | 74 | 79 | 15.2 |
