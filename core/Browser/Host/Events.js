export const capture = (target, name, handler) => { target.addEventListener(name, handler, true); return (_) => { target.removeEventListener(name, handler, true); return null; }; };
export const listen = (target, name, handler) => { target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; };
