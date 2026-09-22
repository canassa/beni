export function run(text) {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false, issues: [{ path: [], code: "invalid_json" }] };
  }
}

export default run;
