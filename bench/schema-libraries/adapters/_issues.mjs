export function pointerPath(pointer) {
  if (pointer === "") return [];
  return pointer.slice(1).split("/").map((segment) => {
    const value = segment.replaceAll("~1", "/").replaceAll("~0", "~");
    return /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value;
  });
}

export function ajvIssues(errors) {
  return (errors ?? []).map((error) => {
    const path = pointerPath(error.instancePath);
    if (error.keyword === "required") path.push(error.params.missingProperty);
    if (error.keyword === "additionalProperties") path.push(error.params.additionalProperty);
    return { path, code: error.keyword };
  });
}

const UNION_BRANCH = { user: 0, count: 1, text: 2, point: 3 };

export function selectedUnionErrors(errors, value) {
  return errors.filter((error) => {
    const match = error.schemaPath.match(/\/oneOf\/(\d+)(?:\/|$)/);
    if (!match) return !/(?:oneOf|anyOf)$/.test(error.keyword);
    const path = pointerPath(error.instancePath);
    const index = path.find((segment) => typeof segment === "number");
    const selected = UNION_BRANCH[value?.[index]?.kind];
    return selected === undefined || Number(match[1]) === selected;
  });
}

export function typiaPath(path) {
  const result = [];
  const source = path.startsWith("$input") ? path.slice(6) : path;
  const pattern = /\.([A-Za-z_$][\w$]*)|\[(\d+)\]|\["((?:[^"\\]|\\.)*)"\]/g;
  for (const match of source.matchAll(pattern)) {
    if (match[1] !== undefined) result.push(match[1]);
    else if (match[2] !== undefined) result.push(Number(match[2]));
    else result.push(JSON.parse(`"${match[3]}"`));
  }
  return result;
}

export function typiaIssues(errors) {
  return errors.map((error) => ({ path: typiaPath(error.path), code: "type" }));
}

export function typeboxIssues(errors) {
  const issues = [];
  const seen = new Set();
  const add = (path, code) => {
    const key = JSON.stringify(path);
    if (!seen.has(key)) {
      seen.add(key);
      issues.push({ path, code });
    }
  };
  for (const error of errors) {
    const path = pointerPath(error.instancePath);
    if (error.keyword === "required") {
      for (const property of error.params.requiredProperties) add([...path, property], error.keyword);
    } else if (error.keyword === "additionalProperties") {
      for (const property of error.params.additionalProperties) add([...path, property], error.keyword);
    } else {
      add(path, error.keyword);
    }
  }
  return issues;
}
