// A platform whose manifest declares `"exports": "program"` (boundary.md
// §5.2, §9.12 (c)): `run` returns what the entry file exports — its
// `default`, and `exports(name)` for each name the app's beni.json lists,
// called once at load, in the list's order. Each call prints, so the
// program's output pins the order and the names.
import process from "node:process";

export const run = (program) => {
  process.stdout.write(`run: ${program.text}\n`);
  return {
    default: { text: program.text },
    exports: (name) => {
      process.stdout.write(`export ${name}\n`);
      return { name };
    },
  };
};
