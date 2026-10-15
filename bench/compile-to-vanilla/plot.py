# /// script
# dependencies = ["matplotlib==3.10.7"]
# ///
"""Standalone figures; raw data and fits remain in sizes.json."""
import json
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
here = Path(__file__).resolve().parent
sizes = json.loads((here / "results/sizes.json").read_text())
plt.rcParams.update({"svg.fonttype": "none", "font.size": 9, "svg.hashsalt": "beni-172"})
for shape in ("varied", "repeated"):
    fig, axes = plt.subplots(2, 3, figsize=(11, 6.5), layout="constrained")
    for ax, family in zip(axes.flat, ("dashboard", "form", "crud", "board", "route", "fanout")):
        for mode in ("vanilla", "lexical", "indexed", "signals", "scan", "expanded"):
            if shape == "varied" and mode == "expanded":
                continue  # byte-identical to lexical on this axis
            points = [p for p in sizes["observations"] if p["shape"] == shape and p["family"] == family and p["mode"] == mode]
            ax.plot([p["count"] for p in points], [p["brotli"] for p in points], marker="o", markersize=3, label=mode)
        ax.set_title(family)
        ax.set_xlabel("features")
        ax.set_ylabel("brotli bytes")
        ax.set_ylim(bottom=0)
        ax.grid(alpha=.2)
    handles, labels = axes.flat[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="outside lower center", ncol=6)
    fig.suptitle(f"Synthetic {shape} features — one production JS response")
    output = here / f"results/{shape}.svg"
    fig.savefig(output, metadata={"Date": None})
    output.write_text("\n".join(line.rstrip() for line in output.read_text().splitlines()) + "\n")
    plt.close(fig)
print("Wrote varied.svg and repeated.svg")
