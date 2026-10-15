const String$toLower = (s$1) => s$1.toLowerCase();
const String$fromInt = (n$1) => globalThis.String(n$1);
const String$fromFloat = (n$1) => globalThis.Number.isInteger(n$1) ? `${n$1}.0` : globalThis.String(n$1);
const String$elements = (xs$1) => globalThis.Array.isArray(xs$1) ? xs$1 : xs$1.$plain();
const String$join = (chunks$1, sep$2) => String$elements(chunks$1).join(sep$2);
export { String$toLower, String$fromInt, String$fromFloat, String$join };
//# sourceMappingURL=String.mjs.map
