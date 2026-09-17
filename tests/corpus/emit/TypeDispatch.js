import { String$fromInt } from "./core/String.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const TypeDispatch$fromInt = (n$1) => ({ $: "Metre", a: n$1 });
const TypeDispatch$make = ($m$0, n$1) => $m$0(n$1);
const TypeDispatch$asMetre = TypeDispatch$make(TypeDispatch$fromInt, 7);
const TypeDispatch$asString = TypeDispatch$make(String$fromInt, 42);
const TypeDispatch$main = Node$printLines({ $: 0, a: null, b: null });
export { TypeDispatch$main, TypeDispatch$fromInt, TypeDispatch$asMetre, TypeDispatch$asString };
