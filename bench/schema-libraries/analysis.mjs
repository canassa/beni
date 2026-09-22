import { cellKey } from "./measure-common.mjs";

function comparable(cell) {
  return cell && !cell.unsupported && !cell.measurement_failed && cell.warmup?.converged === true && cell.summary?.median_ns_per_op !== null;
}

function orderingsFor(cells) {
  const output = [];
  const dimensions = [...new Set(cells.filter(comparable).map((cell) => `${cell.workload}\u0000${cell.direction}\u0000${cell.path}`))];
  for (const dimension of dimensions) {
    const [workload, direction, path] = dimension.split("\u0000");
    const ranked = cells.filter((cell) => comparable(cell) && cell.workload === workload && cell.direction === direction && cell.path === path).sort((a, b) => a.summary.median_ns_per_op - b.summary.median_ns_per_op);
    output.push({ workload, direction, path, ranking: ranked.map((cell) => cell.row), medians_ns_per_op: Object.fromEntries(ranked.map((cell) => [cell.row, cell.summary.median_ns_per_op])) });
  }
  return output;
}

function flipsFor(subjects, identity) {
  const flips = [];
  const dimensions = new Set(subjects.flatMap((subject) => subject.orderings.map((ordering) => `${ordering.workload}\u0000${ordering.direction}\u0000${ordering.path}`)));
  for (const dimension of dimensions) {
    const orderings = subjects.map((subject) => ({ subject, ordering: subject.orderings.find((item) => `${item.workload}\u0000${item.direction}\u0000${item.path}` === dimension) })).filter((item) => item.ordering);
    const rows = [...new Set(orderings.flatMap((item) => item.ordering.ranking))];
    for (let i = 0; i < rows.length; i++) for (let j = i + 1; j < rows.length; j++) {
      const observations = orderings.filter(({ ordering }) => ordering.ranking.includes(rows[i]) && ordering.ranking.includes(rows[j])).map(({ subject, ordering }) => ({
        ...identity(subject),
        sign: Math.sign(ordering.ranking.indexOf(rows[i]) - ordering.ranking.indexOf(rows[j])),
        first_median_ns_per_op: ordering.medians_ns_per_op[rows[i]],
        second_median_ns_per_op: ordering.medians_ns_per_op[rows[j]],
      }));
      if (observations.length >= 2 && new Set(observations.map((item) => item.sign)).size > 1) flips.push({ dimension: dimension.split("\u0000"), pair: [rows[i], rows[j]], observations });
    }
  }
  return flips;
}

export function analyze(processes) {
  const rawProcesses = processes.map((process) => ({ group: process.group, repetition: process.repetition, rotation: process.rotation, row_order: process.row_order, orderings: orderingsFor(process.cells) }));
  const groups = [];
  for (const groupId of [...new Set(processes.map((item) => item.group))].sort()) {
    const repetitions = processes.filter((item) => item.group === groupId);
    const candidates = new Map();
    for (const process of repetitions) for (const cell of process.cells) {
      if (!comparable(cell)) continue;
      const key = cellKey(cell);
      const list = candidates.get(key) ?? [];
      list.push({ repetition: process.repetition, cell });
      candidates.set(key, list);
    }
    const selected = [];
    for (const values of candidates.values()) {
      values.sort((a, b) => a.cell.summary.median_ns_per_op - b.cell.summary.median_ns_per_op);
      selected.push({ ...values[0].cell, selected_repetition: values[0].repetition, repetition_medians: values.map((value) => ({ repetition: value.repetition, median_ns_per_op: value.cell.summary.median_ns_per_op })) });
    }
    const floor = new Map(selected.filter((cell) => cell.row === "json-floor").map((cell) => [`${cell.workload}\u0000${cell.direction}\u0000${cell.path}`, cell.summary.median_ns_per_op]));
    for (const cell of selected) {
      const baseline = floor.get(`${cell.workload}\u0000${cell.direction}\u0000${cell.path}`);
      cell.net_of_json_floor_ns_per_op = baseline === undefined ? null : cell.summary.median_ns_per_op - baseline;
      cell.failure_net_caveat = cell.direction === "encode" && cell.path !== "valid" ? "Encode failures skip serialization; net-of-stringify is counterfactual, not validation-only time." : null;
    }
    groups.push({ group: groupId, selected, orderings: orderingsFor(selected) });
  }
  const ceilingAudits = [];
  for (const group of groups) for (const ordering of group.orderings) {
    const handwritten = ordering.ranking.indexOf("handwritten");
    const faster = handwritten < 0 ? [] : ordering.ranking.slice(0, handwritten).filter((row) => row !== "json-floor");
    if (faster.length > 0) ceilingAudits.push({ group: group.group, workload: ordering.workload, direction: ordering.direction, path: ordering.path, rows_beating_handwritten: faster, action: "Audit equivalent work; retain the measured ordering." });
  }
  const allCells = processes.flatMap((process) => process.cells.filter(comparable).map((cell) => ({ process, cell })));
  const rawRanges = [...new Set(allCells.map(({ cell }) => cellKey(cell)))].map((key) => {
    const values = allCells.filter(({ cell }) => cellKey(cell) === key);
    const sample = values[0].cell;
    const medians = values.map(({ process, cell }) => ({ group: process.group, repetition: process.repetition, median_ns_per_op: cell.summary.median_ns_per_op }));
    return { row: sample.row, workload: sample.workload, direction: sample.direction, path: sample.path, minimum_median_ns_per_op: Math.min(...medians.map((item) => item.median_ns_per_op)), maximum_median_ns_per_op: Math.max(...medians.map((item) => item.median_ns_per_op)), process_medians: medians };
  });
  const warmupNonconvergence = processes.flatMap((process) => process.cells.filter((cell) => !cell.unsupported && !cell.measurement_failed && cell.warmup && !cell.warmup.converged).map((cell) => ({ group: process.group, repetition: process.repetition, row: cell.row, workload: cell.workload, direction: cell.direction, path: cell.path })));
  const measurementFailures = processes.flatMap((process) => process.cells.filter((cell) => cell.measurement_failed).map((cell) => ({ group: process.group, repetition: process.repetition, ...cell })));
  const unsupported = processes.flatMap((process) => process.cells.filter((cell) => cell.unsupported).map((cell) => ({ group: process.group, repetition: process.repetition, row: cell.row, workload: cell.workload, direction: cell.direction, path: cell.path, reason: cell.reason })));
  return {
    groups,
    best_of_group_pairwise_flips: flipsFor(groups, (group) => ({ group: group.group })),
    raw_process_orderings: rawProcesses,
    raw_process_pairwise_flips: flipsFor(rawProcesses, (process) => ({ group: process.group, repetition: process.repetition })),
    raw_process_median_ranges: rawRanges,
    handwritten_ceiling_audits: ceilingAudits,
    warmup_nonconvergence: warmupNonconvergence,
    measurement_failures: measurementFailures,
    unsupported,
  };
}
