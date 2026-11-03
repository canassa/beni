import { Schema$describedField, Schema$describedOf, Schema$int, Schema$describedRecord, Schema$describedVariant, Schema$describedList, Schema$describedTagged, Schema$describedRecursive, Schema$declared, Schema$checkedInput, Schema$describe } from "./_core/Schema.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaDescriptionOnly$Maybe$Nothing = { $: "Nothing", a: null };
const SchemaDescriptionOnly$Tree$$description = Schema$describedRecursive("Tree", ($self) => Schema$describedTagged("kind", [Schema$describedVariant("Leaf", "leaf", { $: "Just", a: Schema$describedRecord([Schema$describedField("value", "value", false, Schema$describedOf(Schema$int))]) }), Schema$describedVariant("Branch", "branch", { $: "Just", a: Schema$describedRecord([Schema$describedField("children", "children", false, Schema$describedList($self))]) })]));
const SchemaDescriptionOnly$Tree$$declared = Schema$declared(($input$1) => Schema$checkedInput("[\"?\",[]]", $input$1), ($input$2) => Schema$checkedInput("[\"?\",[]]", $input$2), "SchemaDescriptionOnly.Tree.Encoded", "SchemaDescriptionOnly.Tree.Type", () => SchemaDescriptionOnly$Tree$$description, SchemaDescriptionOnly$Maybe$Nothing, SchemaDescriptionOnly$Maybe$Nothing, [], SchemaDescriptionOnly$Maybe$Nothing, SchemaDescriptionOnly$Maybe$Nothing, SchemaDescriptionOnly$Maybe$Nothing, SchemaDescriptionOnly$Maybe$Nothing, SchemaDescriptionOnly$Maybe$Nothing);
const SchemaDescriptionOnly$Tree$$schema = ($u$3) => SchemaDescriptionOnly$Tree$$declared;
const SchemaDescriptionOnly$main = Node$printLines([Schema$describe(SchemaDescriptionOnly$Tree$$schema(null)).root.$ === "Reference" ? "a reference" : "something else"]);
export { SchemaDescriptionOnly$main };
//# sourceMappingURL=SchemaDescriptionOnly.mjs.map
