#!/usr/bin/env python3
"""Generate private beni Web IDL conversions; never loaded by applications."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gpu_types", Path(__file__).with_name("generate_types.py"))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
ROOT = t.ROOT


def encoder(native, value, depth=0):
    variable = "part" + str(depth)
    if native.endswith("?"):
        return "nullable (λ" + variable + " → " + encoder(native[:-1], variable, depth + 1) + ") " + value
    if native.startswith("sequence<"):
        return "nativeArray " + value + " (λ" + variable + " → " + encoder(native[9:-1], variable, depth + 1) + ")"
    if native in t.HANDLES or native in ["USVString", "DOMString", "boolean", "[Clamp] unsigned short"]:
        return "Js.from " + value
    scalar = {"GPUSize64": "size64Value", "GPUIntegerCoordinate": "u32Value", "GPUIndex32": "u32Value", "GPUSize32": "u32Value", "GPUBufferDynamicOffset": "u32Value", "GPUStencilValue": "u32Value", "GPUSampleMask": "u32Value", "GPUDepthBias": "i32Value", "GPUSignedOffset32": "i32Value", "double": "f64Value", "float": "f32Value", "GPUPipelineConstantValue": "f64Value"}
    if native in scalar:
        return "Js.from (Scalar." + scalar[native] + " " + value + ")"
    flags = {"GPUBufferUsageFlags": "bufferUsageValue", "GPUTextureUsageFlags": "textureUsageValue", "GPUShaderStageFlags": "shaderStageValue", "GPUMapModeFlags": "mapModeValue", "GPUColorWriteFlags": "colorWriteValue"}
    if native in flags:
        return "Js.from (Flags." + flags[native] + " " + value + ")"
    custom = {"(HTMLVideoElement or VideoFrame)": "encodeExternalTextureSource", "(GPUPipelineLayout or GPUAutoLayoutMode)": "encodePipelineLayoutMode", "(GPUTexture or GPUTextureView)": "encodeTextureOrView", "GPUBindingResource": "encodeBindingResource", "GPUCopyExternalImageSource": "encodeImageSource", "record<DOMString, (GPUSize64 or undefined)>": "encodeLimits", "record<USVString, GPUPipelineConstantValue>": "encodeConstants", "PredefinedColorSpace": "encodeColorSpace", "GPUError": "encodeGpuError"}
    if native in custom:
        return custom[native] + " " + value
    if native in t.DICTS or native in t.ENUMS or native in ["GPUColor", "GPUOrigin2D", "GPUOrigin3D", "GPUExtent3D"]:
        return "encode" + t.name(native) + " " + value
    raise ValueError("Unreviewed conversion " + native)


def generate():
    out = []
    for native, values in t.ENUMS.items():
        stem = t.name(native)
        out += [f"encode{stem} : Types.{stem} → V", f"encode{stem} value =", "    case value of"]
        out += ["        Types." + t.ctor(native, v) + " → Js.from \"" + v + "\"" for v in values]
        out += ["", f"decode{stem} : V → Types.{stem}", f"decode{stem} value ="]
        for i, v in enumerate(values):
            out += ["    " + ("if" if i == 0 else "else if") + " Js.same value (Js.from \"" + v + "\") then Types." + t.ctor(native, v)]
        out += ["    else broken \"Unexpected " + stem + " value\"", ""]
    for native in t.DICTS:
        stem = t.name(native)
        out += [f"encode{stem} : Types.{stem} → V", f"encode{stem} value =", "    object = Js.object []"]
        for required, typ, field in t.fields_of(native):
            expression = encoder(typ, "value." + t.field_name(field))
            if required:
                out += ['    Js.set object "' + field + '" (' + expression + ')']
            else:
                out += ['    putOption object "' + field + '" value.' + t.field_name(field) + ' (λitem → ' + encoder(typ, 'item') + ')']
        out += ["    object", ""]
    return "\n".join(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    target = ROOT / "zig-out/scratch/Conversions.beni"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(generate())
    output = subprocess.run([str(ROOT / "zig-out/bin/beni"), "fmt", "--stdout", str(target)], check=True, capture_output=True, text=True).stdout
    engine = ROOT / "platforms/browser/Gpu/Engine.beni"
    begin = "-- BEGIN GENERATED WEBGPU CONVERSIONS"
    end = "-- END GENERATED WEBGPU CONVERSIONS"
    before, current = engine.read_text().split(begin)
    generated, after = current.split(end)
    if args.check:
        if generated.strip() != output.strip():
            raise SystemExit("Private GPU conversions differ; regenerate from pinned IDL")
    else:
        engine.write_text(before + begin + "\n\n" + output.strip() + "\n\n" + end + after)
    target.unlink()
