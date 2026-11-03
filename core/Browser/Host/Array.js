export const make = (ignored) => { return []; };
export const getOr = (array, index, fallback) => { return index >>> 0 === index && Object.hasOwn(array, index) ? array[index] : fallback; };
export const set = (array, index, value) => { if (index >>> 0 !== index || index === 4294967295) return false; array[index] = value; return true; };
export const push = (array, value) => { array.push(value); return null; };
export const size = (array) => { return array.length; };
export const fromList = (list) => { return Array.isArray(list) ? list : list.$plain ? list.$plain() : list.b.slice(list.o); };
export const atOr = (array, index, fallback) => { return index >>> 0 === index && Object.hasOwn(array, index) ? array[index] : fallback; };
export const length = (array) => { return array.length; };
export const slice = (array, start) => { return array.slice(start); };
