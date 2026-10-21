import process from "node:process";

export const run = (program) => {
  process.stdout.write(program.text + "\n");
};
