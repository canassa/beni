import * as S from "effect/Schema";
import * as P from "effect/SchemaParser";
import * as I from "effect/SchemaIssue";

export function build(schema, root = schema, references = new Map()) {
  if (schema.$ref) {
    if (!references.has(schema.$ref)) references.set(schema.$ref, S.suspend(() => build(root.$defs[schema.$ref.split("/").at(-1)], root, references)));
    return references.get(schema.$ref);
  }
  if (schema.const !== undefined) return S.Literal(schema.const);
  if (schema.oneOf) return S.Union(schema.oneOf.map((item) => build(item, root, references)));
  switch (schema.type) {
    case "string": return S.String;
    case "boolean": return S.Boolean;
    case "number": return S.Number.check(S.isFinite());
    case "integer": return S.Number.check(S.isInt()); // Number.isSafeInteger at pinned rc.116
    case "array": return S.Array(build(schema.items, root, references));
    case "object": return S.Struct(Object.fromEntries(Object.entries(schema.properties).map(([key, item]) => {
      const child = build(item, root, references);
      return [key, schema.required.includes(key) ? child : S.optionalKey(child)];
    })));
    default: throw new Error(`unsupported Effect shape ${JSON.stringify(schema)}`);
  }
}
// Native formatter owns pointer traversal; hooks avoid needless human prose
// formatting in a path-only benchmark, without bypassing native validation.
const format = I.makeFormatterStandardSchemaV1({ leafHook: (issue) => issue._tag, checkHook: () => "check" });
export function parser(schema) {
  const parse = P.decodeUnknownResult(build(schema), { errors: "first", onExcessProperty: "error" });
  return (value) => {
    const result = parse(value);
    return result._tag === "Success" ? { ok: true, value: result.success } : {
      ok: false, issues: format(result.failure).issues.map((issue) => ({ path: [...(issue.path ?? [])], code: issue.message })),
    };
  };
}
