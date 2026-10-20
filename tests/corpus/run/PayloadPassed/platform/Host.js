// `same` hands the record back. `readDrop` is the only read of `drop`.
// A missing field is a host bug, so anything else is rethrown.

export const same = (r) => r;

export const readDrop = (r) => {
    const n = r.drop;
    if (!Number.isSafeInteger(n)) {
        throw new TypeError("drop");
    }
    return n;
};
