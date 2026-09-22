import * as z from "zod";

const MAX_SAFE = 9007199254740991;
const safeInt = () => z.number().int().min(-MAX_SAFE).max(MAX_SAFE);

function parser(shape, jitless) {
  const built = z.strictObject(shape);
  return (value) => {
    const result = built.safeParse(value, { jitless });
    if (result.success) return { ok: true, value: result.data };
    return { ok: false, issues: result.error.issues.flatMap((issue) => issue.code === "unrecognized_keys"
      ? issue.keys.map((key) => ({ path: [...issue.path, key], code: issue.code }))
      : [{ path: issue.path, code: issue.code }]) };
  };
}

export function wireParser(jitless = false) {
  return parser({
    "user-id": safeInt(),
    "display-name": z.string(),
    email: z.string(),
    age: safeInt(),
    active: z.boolean(),
    score: z.number(),
    role: z.string(),
    nickname: z.string().exactOptional(),
  }, jitless);
}

export function programParser(jitless = false) {
  return parser({
    userId: safeInt(),
    displayName: z.string(),
    email: z.string(),
    age: safeInt(),
    active: z.boolean(),
    score: z.number(),
    role: z.string(),
    nickname: z.string().exactOptional(),
  }, jitless);
}
