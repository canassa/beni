const JsDevelopment$devOnly = () => "a development build";
const JsDevelopment$describe = () => JsDevelopment$devOnly();
const JsDevelopment$check = (n$1) => n$1 + 1;
const JsDevelopment$flag = true;
const JsDevelopment$noted = () => globalThis.console.log("noted in a development build");
const JsDevelopment$note = () => {
  JsDevelopment$noted();
  return 1;
};
export { JsDevelopment$describe, JsDevelopment$check, JsDevelopment$flag, JsDevelopment$note };
//# sourceMappingURL=JsDevelopment.mjs.map
