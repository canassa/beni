export const listen = (target, name, handler) => { target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; };
