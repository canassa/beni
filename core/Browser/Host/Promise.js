export const promise = (resolvers) => { return resolvers.promise; };
export const resolve = (resolvers, value) => { resolvers.resolve(value); return null; };
export const reject = (resolvers, reason) => { resolvers.reject(reason); return null; };
export const after = (promise, done) => { return promise.then(done); };
export const observe = (promise, done, failed) => { promise.then(done, failed); return null; };
export const unitResolvers = (ignored) => { return globalThis.Promise.withResolvers(); };
export const stringResolvers = (ignored) => { return globalThis.Promise.withResolvers(); };
export const dataResolvers = (ignored) => { return globalThis.Promise.withResolvers(); };
