export const activated = (_) => { const state = globalThis.navigator.userActivation; return state == null || state.isActive === true; };
