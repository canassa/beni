import { Schema$compiledFail, Schema$declared, Schema$checkedInput, Schema$decode } from "./_core/Schema.mjs";
import { Node$print } from "./_platform/Node.mjs";
import { String$fromInt } from "./_core/String.mjs";
const SchemaWorkerSlots$Maybe$Nothing = { $: "Nothing", a: null };
const SchemaWorkerSlots$Number$$decode = (c, d, p, k, n, v) => {
  let $r$1;
  if (!globalThis.Number.isSafeInteger(v)) {
    $r$1 = Schema$compiledFail("[\"i\",[]]", c, p, k, n, 4, "expected a safe integer", v, false);
  } else {
    $r$1 = v;
  }
  return $r$1;
};
const SchemaWorkerSlots$Number$$declared = Schema$declared(($input$1) => Schema$checkedInput("[\"i\",[]]", $input$1), ($input$2) => Schema$checkedInput("[\"i\",[]]", $input$2), "core:Basics.Int", "core:Basics.Int", () => undefined, SchemaWorkerSlots$Maybe$Nothing, SchemaWorkerSlots$Maybe$Nothing, [], { $: "Just", a: SchemaWorkerSlots$Number$$decode }, SchemaWorkerSlots$Maybe$Nothing, SchemaWorkerSlots$Maybe$Nothing, SchemaWorkerSlots$Maybe$Nothing, SchemaWorkerSlots$Maybe$Nothing);
const SchemaWorkerSlots$Number$$schema = ($u$3) => SchemaWorkerSlots$Number$$declared;
const SchemaWorkerSlots$main = (() => {
  const $t$1 = Schema$decode("core:Basics.Int", "[\"i\",[]]", "core:Basics.Int", SchemaWorkerSlots$Number$$schema(null), 42);
  let $t$2;
  if ($t$1.$ === "Ok") {
    const result$1 = $t$1.a;
    $t$2 = Node$print(String$fromInt(result$1));
  } else {
    $t$2 = Node$print("failed");
  }
  return $t$2;
})();
export { SchemaWorkerSlots$main };
//# sourceMappingURL=SchemaWorkerSlots.mjs.map
