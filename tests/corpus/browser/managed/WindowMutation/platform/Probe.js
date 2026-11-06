// The host may define its own window property; runtime probes must observe it.
export const installWindow = (unit) => { globalThis.window = true; return null; };
