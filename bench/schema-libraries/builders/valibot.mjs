import * as v from "valibot";

export function build(schema, root = schema, references = new Map()) {
  if (schema.$ref) {
    if (!references.has(schema.$ref)) references.set(schema.$ref, v.lazy(() => build(root.$defs[schema.$ref.split("/").at(-1)], root, references)));
    return references.get(schema.$ref);
  }
  if (schema.const !== undefined) return v.literal(schema.const);
  if (schema.oneOf) return v.variant("kind", schema.oneOf.map((item) => build(item, root, references)));
  switch (schema.type) {
    case "string": return v.string();
    case "boolean": return v.boolean();
    case "number": return v.pipe(v.number(), v.finite());
    case "integer": return v.pipe(v.number(), v.integer(), v.minValue(schema.minimum), v.maxValue(schema.maximum));
    case "array": return v.array(build(schema.items, root, references));
    case "object": return v.strictObject(Object.fromEntries(Object.entries(schema.properties).map(([key, item]) => {
      const child = build(item, root, references);
      return [key, schema.required.includes(key) ? child : v.exactOptional(child)];
    })));
    default: throw new Error(`unsupported Valibot shape ${JSON.stringify(schema)}`);
  }
}
export function parser(schema) {
  const built = build(schema);
  return (value) => {
    const result = v.safeParse(built, value, { abortEarly: true, abortPipeEarly: true });
    return result.success ? { ok: true, value: result.output } : { ok: false, issues: result.issues.map((issue) => ({
      path: (issue.path ?? []).map((part) => part.key), code: issue.type,
    })) };
  };
}
