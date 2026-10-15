import { String$fromInt } from "../_core/String.mjs";
const Debug$showFloat = (value$1) => {
  const text$2 = globalThis.String(value$1);
  if (globalThis.Object.is(value$1, 0 - 0.0)) {
    return "-0.0";
  } else {
    return globalThis.Number.isInteger(value$1) && !text$2.includes("e") ? `${text$2}.0` : text$2;
  }
};
const Debug$push = (parts$1, text$2) => parts$1.push(text$2);
const Debug$joined = (parts$1, separator$2) => parts$1.join(separator$2);
const Debug$quoted = (s$1, quote$2) => {
  const parts$3 = [];
  for (const ch$6 of globalThis.Array.from(s$1)) {
    const text$7 = ch$6;
    const code$8 = ch$6.codePointAt(0);
    let $t$1;
    if (text$7 === quote$2 || text$7 === "\\") {
      $t$1 = `\\${text$7}`;
    } else {
      let $t$2;
      if (text$7 === "\n") {
        $t$2 = "\\n";
      } else {
        let $t$3;
        if (text$7 === "\r") {
          $t$3 = "\\r";
        } else {
          let $t$4;
          if (text$7 === "\t") {
            $t$4 = "\\t";
          } else {
            let $t$5;
            if (code$8 < 32 || code$8 === 127) {
              const hex$10 = code$8.toString(16).toUpperCase();
              $t$5 = `\\u{${hex$10}}`;
            } else {
              $t$5 = text$7;
            }
            $t$4 = $t$5;
          }
          $t$3 = $t$4;
        }
        $t$2 = $t$3;
      }
      $t$1 = $t$2;
    }
    const escaped$9 = $t$1;
    Debug$push(parts$3, escaped$9);
  }
  const body$4 = Debug$joined(parts$3, "");
  const unbraced$5 = quote$2 === "\"" ? body$4.split("${").join("\\${") : body$4;
  return `${quote$2}${unbraced$5}${quote$2}`;
};
const Debug$plain = (value$1) => globalThis.Array.isArray(value$1) ? value$1 : value$1.$plain();
const Debug$commas = (parts$1) => Debug$joined(parts$1, ",");
const Debug$parenthesised = (s$1) => {
  const first$2 = s$1[0];
  const bracketed$3 = first$2 === "(" || first$2 === "[" || first$2 === "{" || first$2 === "\"" || first$2 === "'" || first$2 === "<";
  return first$2 === "-" || !bracketed$3 && s$1.includes(" ") ? `(${s$1})` : s$1;
};
const Debug$fieldList = (fields$1) => Debug$joined(fields$1, ", ");
const Debug$untypedObject = (value$1, seen$2) => {
  if (globalThis.Array.isArray(value$1) || typeof value$1.$plain === "function") {
    const parts$3 = [];
    for (const item$4 of Debug$plain(value$1)) {
      Debug$push(parts$3, Debug$untypedValue(item$4, seen$2));
    }
    return `[${Debug$commas(parts$3)}]`;
  } else {
    const keys$5 = globalThis.Object.keys(value$1);
    const tag$6 = value$1.$;
    if (typeof tag$6 === "string") {
      const parts$7 = [tag$6];
      for (const k$8 of keys$5) {
        if (!(k$8 === "$" || value$1[k$8] == null)) {
          Debug$push(parts$7, Debug$parenthesised(Debug$untypedValue(value$1[k$8], seen$2)));
        }
      }
      return Debug$joined(parts$7, " ");
    } else {
      if (keys$5.length === 0) {
        return "{}";
      } else {
        const fields$9 = [];
        for (const k$10 of keys$5) {
          const key$11 = k$10;
          Debug$push(fields$9, `${key$11} = ${Debug$untypedValue(value$1[k$10], seen$2)}`);
        }
        return `{ ${Debug$fieldList(fields$9)} }`;
      }
    }
  }
};
const Debug$untypedValue = (value$1, seen$2) => {
  if (typeof value$1 === "string") {
    return Debug$quoted(value$1, "\"");
  } else {
    if (typeof value$1 === "number") {
      return globalThis.String(value$1);
    } else {
      if (typeof value$1 === "boolean") {
        return value$1 ? "True" : "False";
      } else {
        if (value$1 == null) {
          return "⊤";
        } else {
          if (typeof value$1 === "function") {
            return "<function>";
          } else {
            if (typeof value$1 === "object") {
              if (seen$2.has(value$1)) {
                return "<cycle>";
              } else {
                seen$2.add(value$1);
                try {
                  return Debug$untypedObject(value$1, seen$2);
                } finally {
                  seen$2.delete(value$1);
                }
              }
            } else {
              return "<internals>";
            }
          }
        }
      }
    }
  }
};
const Debug$showCode = (t$1, defs$2, env$3, value$4) => {
  if (t$1 === "i") {
    return globalThis.String(value$4);
  } else {
    if (t$1 === "f") {
      return Debug$showFloat(value$4);
    } else {
      if (t$1 === "s") {
        return Debug$quoted(value$4, "\"");
      } else {
        if (t$1 === "c") {
          return Debug$quoted(value$4, "'");
        } else {
          if (t$1 === "b") {
            return value$4 ? "True" : "False";
          } else {
            if (t$1 === "u") {
              return "⊤";
            } else {
              if (t$1 === "F") {
                return "<function>";
              } else {
                return t$1 === "x" ? "<internals>" : Debug$untypedValue(value$4, new globalThis.Set());
              }
            }
          }
        }
      }
    }
  }
};
const Debug$eachIndex = (i$1, n$2, f$3) => {
  while (i$1 < n$2) {
    f$3(i$1);
    i$1 = i$1 + 1;
  }
  return null;
};
const Debug$slot = (i$1) => i$1 < 26 ? globalThis.String.fromCharCode(97 + i$1) : `a${String$fromInt(i$1)}`;
const Debug$listItems = (t$1, defs$2, env$3, value$4) => {
  const parts$5 = [];
  for (const item$6 of Debug$plain(value$4)) {
    Debug$push(parts$5, Debug$show(t$1, defs$2, env$3, item$6));
  }
  return parts$5;
};
const Debug$dictPairs = (k$1, v$2, defs$3, env$4, tree$5, out$6) => {
  while (tree$5.$ === "Node") {
    Debug$dictPairs(k$1, v$2, defs$3, env$4, tree$5.d, out$6);
    const key$7 = Debug$show(k$1, defs$3, env$4, tree$5.b);
    const entry$8 = v$2 === "?" ? key$7 : `(${key$7},${Debug$show(v$2, defs$3, env$4, tree$5[Debug$slot(2)])})`;
    Debug$push(out$6, entry$8);
    tree$5 = tree$5.e;
  }
};
const Debug$showType = (def$1, env$2, defs$3, value$4) => {
  if (typeof value$4 === "string") {
    return value$4;
  } else {
    const tag$5 = value$4.$;
    if (globalThis.Object.hasOwn(def$1, tag$5)) {
      const args$6 = def$1[tag$5];
      const parts$7 = [tag$5];
      const n$8 = args$6.length;
      Debug$eachIndex(0, n$8, (i$9) => Debug$push(parts$7, Debug$parenthesised(Debug$show(args$6[i$9], defs$3, env$2, value$4[Debug$slot(i$9)]))));
      return Debug$joined(parts$7, " ");
    } else {
      return Debug$untypedValue(value$4, new globalThis.Set());
    }
  }
};
const Debug$bindArgs = (t$1, env$2) => {
  const bound$3 = [];
  const n$4 = t$1.length;
  Debug$eachIndex(2, n$4, (i$5) => {
    const arg$6 = t$1[i$5];
    return typeof arg$6 === "number" ? bound$3.push(env$2[arg$6]) : bound$3.push([arg$6, env$2]);
  });
  return bound$3;
};
const Debug$showApplied = (t$1, defs$2, env$3, value$4) => {
  const head$5 = t$1[0];
  if (head$5 === "t") {
    const parts$6 = [];
    const n$7 = t$1.length;
    Debug$eachIndex(1, n$7, (i$8) => Debug$push(parts$6, Debug$show(t$1[i$8], defs$2, env$3, value$4[Debug$slot(i$8 - 1)])));
    return `(${Debug$commas(parts$6)})`;
  } else {
    if (head$5 === "l") {
      return `[${Debug$commas(Debug$listItems(t$1[1], defs$2, env$3, value$4))}]`;
    } else {
      if (head$5 === "D") {
        const pairs$9 = [];
        Debug$dictPairs(t$1[1], t$1[2], defs$2, env$3, value$4.a, pairs$9);
        return `Dict.fromList [${Debug$commas(pairs$9)}]`;
      } else {
        if (head$5 === "S") {
          const keys$10 = [];
          Debug$dictPairs(t$1[1], "?", defs$2, env$3, value$4.a.a, keys$10);
          return `Set.fromList [${Debug$commas(keys$10)}]`;
        } else {
          return Debug$showType(defs$2[t$1[1]], Debug$bindArgs(t$1, env$3), defs$2, value$4);
        }
      }
    }
  }
};
const Debug$showRecord = (t$1, defs$2, env$3, value$4) => {
  const keys$5 = globalThis.Object.keys(value$4);
  if (keys$5.length === 0) {
    return "{}";
  } else {
    const fields$6 = [];
    for (const k$7 of keys$5) {
      const key$8 = k$7;
      const field$9 = globalThis.Object.hasOwn(t$1, k$7) ? Debug$show(t$1[k$7], defs$2, env$3, value$4[k$7]) : Debug$untypedValue(value$4[k$7], new globalThis.Set());
      Debug$push(fields$6, `${key$8} = ${field$9}`);
    }
    return `{ ${Debug$fieldList(fields$6)} }`;
  }
};
const Debug$show = (t$1, defs$2, env$3, value$4) => {
  while (typeof t$1 === "number") {
    const bound$5 = env$3[t$1];
    t$1 = bound$5[0];
    env$3 = bound$5[1];
  }
  if (typeof t$1 === "string") {
    return Debug$showCode(t$1, defs$2, env$3, value$4);
  } else {
    return globalThis.Array.isArray(t$1) ? Debug$showApplied(t$1, defs$2, env$3, value$4) : Debug$showRecord(t$1, defs$2, env$3, value$4);
  }
};
const Debug$toStringAs = (descriptor$1, value$2) => {
  const parsed$3 = globalThis.JSON.parse(descriptor$1);
  return Debug$show(parsed$3[0], parsed$3[1], [], value$2);
};
const Debug$logAs = (descriptor$1, tag$2, value$3) => {
  globalThis.console.log(`${tag$2}: ${Debug$toStringAs(descriptor$1, value$3)}`);
  return value$3;
};
const Debug$untyped = "[\"?\",[]]";
const Debug$log = (tag$1, value$2) => Debug$logAs(Debug$untyped, tag$1, value$2);
export { Debug$log, Debug$logAs, Debug$toStringAs };
//# sourceMappingURL=Debug.mjs.map
