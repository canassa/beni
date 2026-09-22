import * as S from "effect/Schema";
import * as P from "effect/SchemaParser";
import * as I from "effect/SchemaIssue";

const format = I.makeFormatterStandardSchemaV1({ leafHook: (issue) => issue._tag, checkHook: () => "check" });

function parser(shape) {
  const parse = P.decodeUnknownResult(S.Struct(shape), { errors: "first", onExcessProperty: "error" });
  return (value) => {
    const result = parse(value);
    return result._tag === "Success" ? { ok: true, value: result.success } : {
      ok: false, issues: format(result.failure).issues.map((issue) => ({ path: [...(issue.path ?? [])], code: issue.message })),
    };
  };
}

const safeInt = () => S.Number.check(S.isInt());
const finite = () => S.Number.check(S.isFinite());

export function wireParser() {
  return parser({
    "user-id": safeInt(),
    "display-name": S.String,
    email: S.String,
    age: safeInt(),
    active: S.Boolean,
    score: finite(),
    role: S.String,
    nickname: S.optionalKey(S.String),
  });
}

export function programParser() {
  return parser({
    userId: safeInt(),
    displayName: S.String,
    email: S.String,
    age: safeInt(),
    active: S.Boolean,
    score: finite(),
    role: S.String,
    nickname: S.optionalKey(S.String),
  });
}
