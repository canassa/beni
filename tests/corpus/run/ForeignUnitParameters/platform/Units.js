let count = 0;

export const tick = () => {
  count += 1;
  return count;
};

export const double = (n) => n * 2;

export const next = (n, unit) => (unit === null ? n + 1 : -1);

export const one = (unit) => (unit === null ? 1 : 0);
