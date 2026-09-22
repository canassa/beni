import * as z from "zod";

export function build(schema, root = schema, references = new Map()) {
  if (schema.$ref) {
    if (!references.has(schema.$ref)) references.set(schema.$ref, z.lazy(() => build(root.$defs[schema.$ref.split("/").at(-1)], root, references)));
    return references.get(schema.$ref);
  }
  if (schema.const !== undefined) return z.literal(schema.const);
  if (schema.oneOf) return z.discriminatedUnion("kind", schema.oneOf.map((item) => build(item, root, references)));
  switch (schema.type) {
    case "string": return z.string();
    case "boolean": return z.boolean();
    case "number": return z.number(); // v4 rejects NaN/Infinity natively
    case "integer": return z.number().int().min(schema.minimum).max(schema.maximum);
    case "array": return z.array(build(schema.items, root, references));
    case "object": return z.strictObject(Object.fromEntries(Object.entries(schema.properties).map(([key, item]) => {
      const child = build(item, root, references);
      return [key, schema.required.includes(key) ? child : child.exactOptional()];
    })));
    default: throw new Error(`unsupported Zod shape ${JSON.stringify(schema)}`);
  }
}
export function parser(schema, jitless = false) {
  const built = build(schema);
  return (value) => {
    const result = built.safeParse(value, { jitless });
    if (result.success) return { ok: true, value: result.data };
    return { ok: false, issues: result.error.issues.flatMap((issue) => issue.code === "unrecognized_keys"
      ? issue.keys.map((key) => ({ path: [...issue.path, key], code: issue.code }))
      : [{ path: issue.path, code: issue.code }]) };
  };
}
