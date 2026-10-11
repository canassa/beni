// Derives the variants from out/lean-direct/_main.mjs (run from bench/ui).
const fs = require("fs");
const lean = fs.readFileSync("out/lean-direct/_main.mjs", "utf8");
const R = (s, a, b) => { if (!s.includes(a)) throw new Error("missing: " + a.slice(0, 80)); return s.replace(a, b); };
const swapIn = `  const rows = model.a;
  if (!swapRows(rows)) return;`;
const swapBuild = (plain) => `  const was = model.a;
  model = { ...model, a: swapRows(was) };
  if (model.a === was) return;
  const rows = ${plain}(model.a);`;
const swapRowsIn = /const swapRows = \(b\) => \{[\s\S]*?\n\};/;
const swapRowsBuild = (get) => `const swapRows = (b) => {
  let c = 1 < b.length ? { $: 0, a: ${get("b", 1)} } : Nothing,
    d = 998 < b.length ? { $: 0, a: ${get("b", 998)} } : Nothing;
  if (c.$ === 0 && d.$ === 0) {
    let f = c.a,
      g = d.a;
    return IM(b, (b, c) => (b === 1 ? g : b === 998 ? f : c));
  }
  return b;
};`;
// (b) markup in the HTML
{
  let s = lean;
  const m = /const root = tpl\("((?:[^"\\]|\\.)*)"\);/.exec(s);
  fs.mkdirSync("out/lean-direct-html", { recursive: true });
  fs.writeFileSync("out/lean-direct-html/body.html", JSON.parse('"' + m[1] + '"') + "</span></div>");
  s = R(s, m[0], "// (b): the page markup is in the HTML, as vanilla keeps it.\nconst root = document.body.firstChild;");
  s = R(s, "document.body.append(root);\n", "");
  fs.writeFileSync("out/lean-direct-html/_main.mjs", s);
}
// strict: the thesis as written -- map/indexedMap/filter build (O1 open), push in place
{
  let s = lean;
  s = R(s, s.slice(s.indexOf("// `List.indexedMap` on an owned list"), s.indexOf("// `xs ++ ys` with `xs` owned")),
    `// \`List.indexedMap\` and \`List.filter\` build (the thesis's O1 is open), keeping
// the identity promise: an unchanged result is the input.
const IM = (a, f) => {
  const n = a.length,
    b = new Array(n);
  let same = true;
  for (let i = 0; i < n; i++) {
    const x = a[i],
      y = f(i, x);
    b[i] = y;
    same = same && x === y;
  }
  return same ? a : b;
};
const filter = (a, p) => {
  const b = [];
  for (let i = 0; i < a.length; i++) if (p(a[i])) b.push(a[i]);
  return b.length === a.length ? a : b;
};
`);
  s = s.replace(swapRowsIn, swapRowsBuild((b, i) => `${b}[${i}]`));
  s = R(s, swapIn, swapBuild(""));
  s = R(s, "indexedMapInPlace(model.a,", "IM(model.a,");
  s = R(s, "filterInPlace(model.a,", "filter(model.a,");
  s = s.replace("const rows = (model.a);", "const rows = model.a;");
  fs.mkdirSync("out/lean-strict", { recursive: true });
  fs.writeFileSync("out/lean-strict/_main.mjs", s.replace("const rows = (model.a)", "const rows = model.a"));
}
// trie: the S3 bundle's persistent List kept (ablation of reduction 1)
{
  const s3 = fs.readFileSync("out/beni-direct-rel/_main.mjs", "utf8");
  const core = s3.slice(0, s3.indexOf(";const D={}") + 1).replace(/^const a=\{\$:1,a:null\},/, "const ");
  let s = lean;
  s = R(s, s.slice(s.indexOf("// `List.indexedMap` on an owned list"), s.indexOf("// ---- program: the model half")), "// core List: the S3 bundle's persistent list, verbatim\n" + core + "\nconst IM = y;\n");
  s = R(s, '? b[e] : ""', '? u(b, e) : ""');
  s = R(s, "d.push({ c: a, f: h });", "d = s(d, [{ c: a, f: h }]);");
  s = s.replace(swapRowsIn, swapRowsBuild((b, i) => `u(${b}, ${i})`));
  s = R(s, swapIn, swapBuild("c"));
  s = R(s, "const reconcile = (rows) => {", "const reconcile = (list) => {\n  const rows = c(list);");
  s = R(s, "const f = document.createDocumentFragment(),\n    rows = model.a;", "const f = document.createDocumentFragment(),\n    rows = c(model.a);");
  s = R(s, "a: appendInPlace(model.a, a.a)", "a: s(model.a, a.a)");
  s = R(s, "a: indexedMapInPlace(model.a,", "a: y(model.a,");
  s = R(s, "const rows = model.a;\n  for (let j", "const rows = c(model.a);\n  for (let j");
  s = R(s, "a: filterInPlace(model.a,", "a: C(model.a,");
  s = R(s, "const rows = model.a,\n    kept", "const rows = c(model.a),\n    kept");
  fs.mkdirSync("out/lean-trie", { recursive: true });
  fs.writeFileSync("out/lean-trie/_main.mjs", s);
}
