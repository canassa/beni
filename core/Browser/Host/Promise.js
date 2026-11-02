export const observe = (promise, done, failed) => { promise.then(done, failed); return null; };
