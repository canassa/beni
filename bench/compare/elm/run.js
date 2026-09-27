// Runs the compiled Elm worker and prints what its `output` port sends.
const path = require("path");
const file = process.argv[2] || path.join(__dirname, "elm.js");
const scope = {};
new Function("scope", require("fs").readFileSync(file, "utf8").replace("(this)", "(scope)"))(scope);
const app = scope.Elm.Main.init();
app.ports.output.subscribe((text) => console.log(text));
