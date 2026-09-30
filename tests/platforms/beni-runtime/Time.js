// The sibling JavaScript of `Time.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name. The clock and the timer
// are the page's, read when called, so a test harness that replaces them
// before the program runs is the clock the program sees.

export const clock = (unit) => globalThis.Date.now();

export const startTimer = (ms, resume) => {
  const timer = globalThis.setTimeout(() => resume(null), ms);
  return (unit) => {
    globalThis.clearTimeout(timer);
    return unit;
  };
};
