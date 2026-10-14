export const wrap = (callback) => ({ callback: callback });
export const run = (program) => program.callback("Dropped");
