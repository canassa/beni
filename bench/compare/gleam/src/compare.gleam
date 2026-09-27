import data
import gleam/io
import gleam/list
import gleam/string
import interp
import tree

pub fn main() -> Nil {
  list.flatten([interp.run(), tree.run(), data.run()])
  |> string.join("\n")
  |> io.println
}
