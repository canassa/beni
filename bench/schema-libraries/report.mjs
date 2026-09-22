function formatNs(value) {
  if (value === null || value === undefined) return "—";
  return value < 1000 ? value.toFixed(1) : Math.round(value).toLocaleString("en-US");
}

export function performanceTables(analysis) {
  return analysis.groups.map((group) => {
    const lines = [
      `### Group ${group.group}`,
      "",
      "| workload | direction | path | row | median ns/op | p10 | p90 | net floor |",
      "|---|---|---|---|---:|---:|---:|---:|",
    ];
    const cells = [...group.selected].sort((a, b) => a.workload.localeCompare(b.workload) || a.direction.localeCompare(b.direction) || a.path.localeCompare(b.path) || a.summary.median_ns_per_op - b.summary.median_ns_per_op);
    for (const cell of cells) lines.push(`| ${cell.workload} | ${cell.direction} | ${cell.path} | ${cell.row} | ${formatNs(cell.summary.median_ns_per_op)} | ${formatNs(cell.summary.p10_ns_per_op)} | ${formatNs(cell.summary.p90_ns_per_op)} | ${formatNs(cell.net_of_json_floor_ns_per_op)} |`);
    return lines.join("\n");
  });
}

export function bundleTable(bundles) {
  const lines = [
    "| row | direction | raw bytes | brotli bytes |",
    "|---|---|---:|---:|",
  ];
  for (const item of bundles) lines.push(`| ${item.row} | ${item.direction} | ${item.raw_bytes ?? "error"} | ${item.brotli_bytes ?? "error"} |`);
  return lines.join("\n");
}

export function startupTable(startup) {
  const lines = [
    "| surface | row | workload | direction | import median ns | construct/compile median ns | first call median ns |",
    "|---|---|---|---|---:|---:|---:|",
  ];
  for (const item of startup.summary) lines.push(`| ${item.surface} | ${item.row} | ${item.workload} | ${item.direction} | ${formatNs(item.import.median_ns)} | ${item.construction_compile === null ? "n/a" : formatNs(item.construction_compile.median_ns)} | ${formatNs(item.first_call.median_ns)} |`);
  return lines.join("\n");
}
