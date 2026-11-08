#!/usr/bin/env python3
"""Audit the pinned research IDL and render its complete coverage checklist.

This reads the simple declaration subset present in this snapshot, not arbitrary
WebIDL. It rejects unconsumed input, so a new construct needs an explicit review.
No network or third-party packages are needed. Run with --check in review.
"""

import argparse
from collections import Counter
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
OWNERS = {
    "GPU": "Gpu; entry point, engine-internal",
    "NavigatorGPU": "Gpu (Window and Worker entry points)",
    "GPUSupportedLimits": "Gpu.Limits; snapshot Gpu.Limits.Limits",
    "GPUSupportedFeatures": "Gpu.Feature; snapshot Gpu.Feature.Features",
    "WGSLLanguageFeatures": "Gpu.WgslFeature; snapshot Gpu.WgslFeature.WgslFeatures",
    "GPUShaderModule": "Gpu.Shader; handle Gpu.Handle.Shader",
    "GPUCompilationMessage": "Gpu.Shader; snapshot record in Gpu.Types.CompilationInfo",
    "GPUCompilationInfo": "Gpu.Shader; snapshot Gpu.Types.CompilationInfo",
    "GPUObjectBase": "label/setLabel in each including interface's operation module (Gpu.Buffer.label, ...)",
    "GPUCommandsMixin": "Gpu.Encode (marker; no members)",
    "GPUDebugCommandsMixin": "Gpu.CommandEncoder / ComputePass / RenderPass / RenderBundleEncoder",
    "GPUBindingCommandsMixin": "Gpu.ComputePass / RenderPass / RenderBundleEncoder",
    "GPURenderCommandsMixin": "Gpu.RenderPass / RenderBundleEncoder",
    "GPUPipelineBase": "Gpu.ComputePipeline / RenderPipeline",
    "GPUComputePassEncoder": "Gpu.ComputePass; handle Gpu.Handle.ComputePass",
    "GPURenderPassEncoder": "Gpu.RenderPass; handle Gpu.Handle.RenderPass",
    "GPUCanvasContext": "Gpu.Surface; handle Gpu.Handle.Surface",
    "GPUError": "Gpu.Error; snapshot in the Gpu.Error sums",
    "GPUValidationError": "Gpu.Error.Validation; snapshot",
    "GPUOutOfMemoryError": "Gpu.Error.OutOfMemory; snapshot",
    "GPUInternalError": "Gpu.Error.Internal; snapshot",
    "GPUPipelineError": "Gpu.Error.Pipeline; snapshot in the Gpu.Error sums",
    "GPUDeviceLostInfo": "Gpu.Error.DeviceLoss; snapshot",
    "GPUUncapturedErrorEvent": "Gpu.Device events; snapshot Gpu.Device.DeviceEvent",
    "GPUAdapterInfo": "Gpu.Adapter.info / Gpu.Device.adapterInfo; snapshot Gpu.Types.AdapterInfo",
    "GPUAdapter": "Gpu.Adapter; handle Gpu.Handle.Adapter",
    "GPUDevice": "Gpu.Device; handle Gpu.Handle.Device",
    "GPUBuffer": "Gpu.Buffer; handle Gpu.Handle.Buffer",
    "GPUTexture": "Gpu.Texture; handle Gpu.Handle.Texture",
    "GPUTextureView": "Gpu.TextureView; handle Gpu.Handle.TextureView",
    "GPUExternalTexture": "Gpu.ExternalTexture; handle Gpu.Handle.ExternalTexture",
    "GPUSampler": "Gpu.Sampler; handle Gpu.Handle.Sampler",
    "GPUBindGroupLayout": "Gpu.BindGroupLayout; handle Gpu.Handle.BindGroupLayout",
    "GPUBindGroup": "Gpu.BindGroup; handle Gpu.Handle.BindGroup",
    "GPUPipelineLayout": "Gpu.PipelineLayout; handle Gpu.Handle.PipelineLayout",
    "GPUComputePipeline": "Gpu.ComputePipeline; handle Gpu.Handle.ComputePipeline",
    "GPURenderPipeline": "Gpu.RenderPipeline; handle Gpu.Handle.RenderPipeline",
    "GPUCommandBuffer": "Gpu.CommandBuffer; handle Gpu.Handle.CommandBuffer",
    "GPUCommandEncoder": "Gpu.CommandEncoder; handle Gpu.Handle.CommandEncoder",
    "GPURenderBundle": "Gpu.RenderBundle; handle Gpu.Handle.RenderBundle",
    "GPURenderBundleEncoder": "Gpu.RenderBundleEncoder; handle Gpu.Handle.RenderBundleEncoder",
    "GPUQueue": "Gpu.Queue; handle Gpu.Handle.Queue",
    "GPUQuerySet": "Gpu.QuerySet; handle Gpu.Handle.QuerySet",
}


def parse(source):
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    declarations = []
    # Every declaration in this snapshot ends at a line containing };, except
    # typedefs/includes. Dictionary default {} therefore cannot end a block.
    pattern = re.compile(
        r"\s*(?:\[[^\]]*\]\s*)?"
        r"(?:(?P<kind>interface mixin|partial interface|interface|dictionary|enum|namespace)"
        r"\s+(?P<name>\w+)(?P<parent>\s*:\s*\w+)?\s*\{(?P<body>.*?)^\};"
        r"|(?P<typedef>typedef\s+.*?;)"
        r"|(?P<includes>\w+\s+includes\s+\w+;))",
        re.S | re.M,
    )
    pos = 0
    while source[pos:].strip():
        match = pattern.match(source, pos)
        if not match:
            raise ValueError(f"Unparsed WebIDL: {source[pos:pos + 120]!r}")
        pos = match.end()
        if match["typedef"]:
            name = re.search(r"(\w+)\s*;$", match["typedef"])[1]
            declarations.append(("typedef", name, "", [" ".join(match["typedef"].split())]))
        elif match["includes"]:
            declarations.append(("includes", " ".join(match["includes"].split()), "", []))
        else:
            kind, name = match["kind"], match["name"]
            if kind == "enum":
                members = re.findall(r'"([^"\n]*)"', match["body"])
            else:
                members = [" ".join(m.split()) + ";" for m in match["body"].split(";") if m.strip()]
            declarations.append((kind, name, (match["parent"] or "").strip(), members))
    return declarations


def owner(kind, name):
    if kind == "namespace":
        return "Gpu.Flags"
    if kind in ("dictionary", "enum", "typedef"):
        return "Gpu.Types (typed descriptors, enums and scalar/union adapters)"
    return OWNERS.get(name, "Gpu." + name.removeprefix("GPU"))


def render(declarations):
    counts = Counter(d[0] for d in declarations)
    result = [
        "# WebGPU coverage inventory",
        "",
        "Generated by `python3 inventory.py` from [webgpu.idl](webgpu.idl).",
        "Run `python3 inventory.py --check` to check the committed checklist.",
        "",
        "**Design coverage, not implementation coverage.** All entries are adopted contract;",
        "none is a claim that a binding has shipped. The complete signatures and",
        "defaults below are the required surface. See [the contract](../../webgpu.md)",
        "§2–§4 for translation rules, and §6 for the managed encoding/scope adapters.",
        "",
        "Counts: " + ", ".join(f"{n} {k}" for k, n in sorted(counts.items())) + ".",
        "",
        "Each interface member has its host spelling in its owning module, except",
        "the explicit adapters in the contract (§3, §6, §8). Includes are listed",
        "separately: all members of the included mixin apply to every including",
        "interface. Partial interface members extend the same owner. Inherited",
        "dictionary fields are required too. No overload, null slot or omitted",
        "member may be discarded by generation.",
        "",
    ]
    for kind, name, parent, members in declarations:
        result += [f"## {kind} `{name}`" + (f" `{parent}`" if parent else ""), ""]
        if kind == "includes":
            result += ["All members of this mixin are covered on the including interface.", ""]
            continue
        result += [f"Owner: `{owner(kind, name)}`.", ""]
        if kind == "enum":
            result += [", ".join(f'`"{m}"`' for m in members) + ".", ""]
        elif members:
            result += ["```webidl", *members, "```", ""]
        else:
            result += ["No own members; includes/inheritance still apply.", ""]
    return "\n".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = render(parse((ROOT / "webgpu.idl").read_text()))
    target = ROOT / "coverage.md"
    if args.check:
        if target.read_text() != output:
            raise SystemExit("coverage.md is stale; run python3 inventory.py")
        print("Pinned WebGPU coverage inventory is complete and current.")
    else:
        target.write_text(output)


if __name__ == "__main__":
    main()
