## 2026-10-30 01:07 CET — Add native binary storage and WebGPU source identities

**What I did**

Implemented Binary in beni over privileged Js intrinsics: fixed and shared native backing, all typed views and DataView, checked source intake, byte ranges, copying, scalar signed/float/f16 access and exact 64-bit words. Added source identity declarations shared by browser Image, Video and Canvas without circular imports. Coordinated their erased native representation with the GPU runtime implementation. Focused binary development/release executions and invalidation probes cover detached aliases, resizable/growable rejection and unknown exceptions escaping as defects. Broader source constructors, transfers and WGSL layout helpers continue in the same implementation branch; this commit makes the agreed dependency usable early.

**What I learned**

AllowShared does not imply AllowResizable: even an in-bounds fixed typed view on resizable backing must be rejected. Native handles preserve invalidation across aliases. Beni's negative zero Float literal is currently normalized to positive zero; filed #1282, while native binary read/write roundtrips retain the sign.
