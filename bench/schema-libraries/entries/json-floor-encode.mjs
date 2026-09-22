export function run(value) {
  try {
    return { ok: true, value: JSON.stringify(value) };
  } catch {
    return { ok: false, issues: [{ path: [], code: "json_stringify" }] };
  }
}

export default run;
