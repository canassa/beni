// Programs shaped like the research benchmark's dashboards (`schema.md` §6, *How a program
// chooses between shapes and workers*): n widget modules, each with a derived record model
// that `Result.withDefault (Json.decodeValue state) model` replaces, and a `Main` that reads
// the host's events with a tagged `schema` whose snapshot names every widget. n widgets make
// n + 1 validator runs with shapes.
export function project(n, seed = 1) {
  const files = {};
  const syl = ["ka", "lo", "mi", "ne", "pu", "ra", "si", "to", "vu", "we", "xi", "yo", "za", "be", "co", "du"];
  const kinds = ["Int", "String", "Bool", "Int", "String", "Float"];
  const pick = (i, j) => (i * 7 + j * 5 + seed * 3) % 16;
  for (let i = 1; i <= n; i++) {
    const count = 2 + ((i + seed) % 3);
    const fields = Array.from({ length: count }, (_, j) => [syl[pick(i, j)] + syl[pick(i + 3, j + 1)] + "W" + i + "F" + j, kinds[(i + j + seed) % kinds.length]]);
    const init = fields.map(([f, k]) => `${f} = ${k === "String" ? '"x"' : k === "Bool" ? "False" : k === "Float" ? "0.5" : "0"}`).join(", ");
    files[`W${i}.beni`] = `import Json
import Schema exposing (Value)


pub type alias Model =
${fields.map(([f, k]) => `    ${f} : ${k}`).join("\n")}


pub init : ⊤ → Model
init ⊤ = { ${init} }


pub replace : Value, Model → Model
replace state model = Result.withDefault (Json.decodeValue state) model


pub size : Model → Int
size model = ${fields.filter(([, k]) => k === "Int").map(([f]) => `model.${f}`).join(" + ") || "0"}
`;
  }
  const ws = Array.from({ length: n }, (_, i) => i + 1);
  files["Main.beni"] = `import Node
import Schema exposing (Value)
${ws.map((i) => `import W${i}`).join("\n")}


type alias Model =
${ws.map((i) => `    w${i} : W${i}.Model`).join("\n")}


schema Event tagged "type" of
    ServerSet as "serverSet"
        widget : String
        state : Value
    Tick as "tick"
    Snapshot as "snapshot"
        state : Snapshot


schema Snapshot =
    widgets : Widgets


schema Widgets =
${ws.map((i) => `    w${i} : Value as "w${i}"`).join("\n")}


replaced : String, Value, Model → Model
replaced widget state model =
    case widget of
${ws.map((i) => `        "w${i}" →\n            { model | w${i} = W${i}.replace state model.w${i} }`).join("\n\n")}

        _ →
            model


pushed : Value, Model → Model
pushed value model =
    case Schema.read (Event.schema ⊤) value of
        Ok (Event.ServerSet event) →
            replaced event.widget event.state model

        Ok Event.Tick →
            model

        Ok (Event.Snapshot event) →
            widgets = event.state.widgets
            { ${ws.map((i) => `w${i} = W${i}.replace widgets.w${i} model.w${i}`).join("\n            , ")}
            }

        Err _ →
            model


main : Node.Program
main =
    model = { ${ws.map((i) => `w${i} = W${i}.init ⊤`).join(", ")} }
    case Schema.parse Schema.value "{\\"type\\":\\"tick\\"}" of
        Ok v →
            next = pushed v model
            Node.print (String.fromInt (${ws.map((i) => `W${i}.size next.w${i}`).join(" + ")}))

        Err _ →
            Node.print "x"
`;
  return files;
}
