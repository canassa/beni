import { Schema$describedOf, Schema$int, Schema$describedField, Schema$describedRecord, Schema$describedVariant, Schema$describedList, Schema$describedTagged, Schema$describedRecursive, Schema$declared, Schema$describe } from "./_core/Schema.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaDescriptionOnly$Maybe$Nothing = { $: "Nothing", a: null };
const SchemaDescriptionOnly$Tree$$description = Schema$describedRecursive("Tree", ($self) => Schema$describedTagged("kind", [Schema$describedVariant("Leaf", "leaf", Schema$describedRecord([Schema$describedField("value", "value", false, Schema$describedOf(Schema$int))], ($p$1) => ({ value: $p$1.b }), ($r$2) => ({ a: null, b: $r$2.value })), ($x$3) => ({ $: "Leaf", a: $x$3 }), ($v$4) => $v$4.$ === "Leaf" ? { $: "Just", a: $v$4.a } : SchemaDescriptionOnly$Maybe$Nothing), Schema$describedVariant("Branch", "branch", Schema$describedRecord([Schema$describedField("children", "children", false, Schema$describedList($self))], ($p$5) => ({ children: $p$5.b }), ($r$6) => ({ a: null, b: $r$6.children })), ($x$7) => ({ $: "Branch", a: $x$7 }), ($v$8) => $v$8.$ === "Branch" ? { $: "Just", a: $v$8.a } : SchemaDescriptionOnly$Maybe$Nothing)]));
const SchemaDescriptionOnly$Tree$$declared = Schema$declared(() => SchemaDescriptionOnly$Tree$$description, null, null, null, null);
const SchemaDescriptionOnly$Tree$$schema = ($u$1) => SchemaDescriptionOnly$Tree$$declared;
const SchemaDescriptionOnly$main = Node$printLines([Schema$describe(SchemaDescriptionOnly$Tree$$schema(null)).root.$ === "Reference" ? "a reference" : "something else"]);
export { SchemaDescriptionOnly$main };
//# sourceMappingURL=SchemaDescriptionOnly.mjs.map
