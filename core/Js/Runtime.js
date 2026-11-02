// Core protocol primitives. Scheduling and cancellation are beni in Task.
const parkedValue = {};
export const parked = (unit) => parkedValue;
export const defect = (message) => { throw new Error(message); };
