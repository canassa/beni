import * as v from "valibot";

const MAX_SAFE = 9007199254740991;
const safeInt = () => v.pipe(v.number(), v.integer(), v.minValue(-MAX_SAFE), v.maxValue(MAX_SAFE));
const finite = () => v.pipe(v.number(), v.finite());

function parser(shape) {
  const built = v.strictObject(shape);
  return (value) => {
    const result = v.safeParse(built, value, { abortEarly: true, abortPipeEarly: true });
    return result.success ? { ok: true, value: result.output } : { ok: false, issues: result.issues.map((issue) => ({
      path: (issue.path ?? []).map((part) => part.key), code: issue.type,
    })) };
  };
}

export function wireParser() {
  return parser({
    "user-id": safeInt(),
    "display-name": v.string(),
    email: v.string(),
    age: safeInt(),
    active: v.boolean(),
    score: finite(),
    role: v.string(),
    nickname: v.exactOptional(v.string()),
  });
}

export function programParser() {
  return parser({
    userId: safeInt(),
    displayName: v.string(),
    email: v.string(),
    age: safeInt(),
    active: v.boolean(),
    score: finite(),
    role: v.string(),
    nickname: v.exactOptional(v.string()),
  });
}
