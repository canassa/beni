import { Basics$add } from "./_core/Basics.mjs";
import { String$toInt, String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const QuestionShape$maybe = (text$1) => {
  const $t$1 = String$toInt(text$1);
  if ($t$1.$ === "Nothing") {
    return $t$1;
  }
  return { $: "Just", a: Basics$add($t$1.a, 1) };
};
const QuestionShape$result = (r$1) => {
  if (r$1.$ === "Err") {
    return r$1;
  }
  return { $: "Ok", a: String$fromInt(r$1.a) };
};
const QuestionShape$atom = (m$1, offset$2) => {
  if (m$1.$ === "Nothing") {
    return m$1;
  }
  return { $: "Just", a: Basics$add(m$1.a, offset$2) };
};
const QuestionShape$twice = (a$1, b$2) => {
  if (a$1.$ === "Nothing") {
    return a$1;
  }
  const $t$2 = a$1.a;
  if (b$2.$ === "Nothing") {
    return b$2;
  }
  return { $: "Just", a: Basics$add($t$2, b$2.a) };
};
const QuestionShape$main = Node$printLines({ $: 0, a: null, b: null });
export { QuestionShape$main, QuestionShape$maybe, QuestionShape$result, QuestionShape$atom, QuestionShape$twice };
