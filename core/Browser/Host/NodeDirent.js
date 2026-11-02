export const name = (entry) => { return entry.name; };
export const isFile = (entry) => { return entry.isFile(); };
export const isDirectory = (entry) => { return entry.isDirectory(); };
export const isSymbolicLink = (entry) => { return entry.isSymbolicLink(); };
