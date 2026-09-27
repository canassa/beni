// A left-leaning red-black tree keyed by Int: insert, remove, lookup,
// folds, map/filter/union, and an invariant checker.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

type Color {
  Red
  Black
}

type Tree(v) {
  Leaf
  Node(Color, Int, v, Tree(v), Tree(v))
}

fn empty() -> Tree(v) {
  Leaf
}

fn get(tree: Tree(v), target: Int) -> Option(v) {
  case tree {
    Leaf -> None
    Node(_, key, value, left, right) ->
      case target < key, target > key {
        True, _ -> get(left, target)
        _, True -> get(right, target)
        _, _ -> Some(value)
      }
  }
}

fn member(tree: Tree(v), target: Int) -> Bool {
  case get(tree, target) {
    Some(_) -> True
    None -> False
  }
}

fn size(tree: Tree(v)) -> Int {
  case tree {
    Leaf -> 0
    Node(_, _, _, left, right) -> 1 + size(left) + size(right)
  }
}

// INSERT

fn insert(tree: Tree(v), key: Int, value: v) -> Tree(v) {
  case insert_help(key, value, tree) {
    Node(Red, k, v, l, r) -> Node(Black, k, v, l, r)
    other -> other
  }
}

fn insert_help(key: Int, value: v, tree: Tree(v)) -> Tree(v) {
  case tree {
    Leaf -> Node(Red, key, value, Leaf, Leaf)
    Node(color, node_key, node_value, left, right) ->
      case key < node_key, key > node_key {
        True, _ ->
          balance(
            color,
            node_key,
            node_value,
            insert_help(key, value, left),
            right,
          )
        _, True ->
          balance(
            color,
            node_key,
            node_value,
            left,
            insert_help(key, value, right),
          )
        _, _ -> Node(color, node_key, value, left, right)
      }
  }
}

fn balance(
  color: Color,
  key: Int,
  value: v,
  left: Tree(v),
  right: Tree(v),
) -> Tree(v) {
  case right {
    Node(Red, r_k, r_v, r_left, r_right) ->
      case left {
        Node(Red, l_k, l_v, l_left, l_right) ->
          Node(
            Red,
            key,
            value,
            Node(Black, l_k, l_v, l_left, l_right),
            Node(Black, r_k, r_v, r_left, r_right),
          )
        _ -> Node(color, r_k, r_v, Node(Red, key, value, left, r_left), r_right)
      }
    _ ->
      case left {
        Node(Red, l_k, l_v, Node(Red, ll_k, ll_v, ll_left, ll_right), l_right) ->
          Node(
            Red,
            l_k,
            l_v,
            Node(Black, ll_k, ll_v, ll_left, ll_right),
            Node(Black, key, value, l_right, right),
          )
        _ -> Node(color, key, value, left, right)
      }
  }
}

// REMOVE

fn remove(tree: Tree(v), key: Int) -> Tree(v) {
  case remove_help(key, tree) {
    Node(Red, k, v, l, r) -> Node(Black, k, v, l, r)
    other -> other
  }
}

fn remove_help(target: Int, tree: Tree(v)) -> Tree(v) {
  case tree {
    Leaf -> Leaf
    Node(color, key, value, left, right) ->
      case target < key {
        True ->
          case left {
            Node(Black, _, _, l_left, _) ->
              case l_left {
                Node(Red, _, _, _, _) ->
                  Node(color, key, value, remove_help(target, left), right)
                _ ->
                  case move_red_left(tree) {
                    Node(n_color, n_key, n_value, n_left, n_right) ->
                      balance(
                        n_color,
                        n_key,
                        n_value,
                        remove_help(target, n_left),
                        n_right,
                      )
                    Leaf -> Leaf
                  }
              }
            _ -> Node(color, key, value, remove_help(target, left), right)
          }
        False ->
          remove_help_eq_gt(
            target,
            remove_help_prep_eq_gt(tree, color, key, value, left, right),
          )
      }
  }
}

fn remove_help_prep_eq_gt(
  tree: Tree(v),
  color: Color,
  key: Int,
  value: v,
  left: Tree(v),
  right: Tree(v),
) -> Tree(v) {
  case left {
    Node(Red, l_k, l_v, l_left, l_right) ->
      Node(color, l_k, l_v, l_left, Node(Red, key, value, l_right, right))
    _ ->
      case right {
        Node(Black, _, _, Node(Black, _, _, _, _), _) -> move_red_right(tree)
        Node(Black, _, _, Leaf, _) -> move_red_right(tree)
        _ -> tree
      }
  }
}

fn remove_help_eq_gt(target: Int, tree: Tree(v)) -> Tree(v) {
  case tree {
    Node(color, key, value, left, right) ->
      case target == key {
        True ->
          case get_min(right) {
            Node(_, min_key, min_value, _, _) ->
              balance(color, min_key, min_value, left, remove_min(right))
            Leaf -> Leaf
          }
        False -> balance(color, key, value, left, remove_help(target, right))
      }
    Leaf -> Leaf
  }
}

fn get_min(tree: Tree(v)) -> Tree(v) {
  case tree {
    Node(_, _, _, Node(_, _, _, _, _) as left, _) -> get_min(left)
    _ -> tree
  }
}

fn remove_min(tree: Tree(v)) -> Tree(v) {
  case tree {
    Node(color, key, value, Node(l_color, _, _, l_left, _) as left, right) ->
      case l_color {
        Black ->
          case l_left {
            Node(Red, _, _, _, _) ->
              Node(color, key, value, remove_min(left), right)
            _ ->
              case move_red_left(tree) {
                Node(n_color, n_key, n_value, n_left, n_right) ->
                  balance(n_color, n_key, n_value, remove_min(n_left), n_right)
                Leaf -> Leaf
              }
          }
        Red -> Node(color, key, value, remove_min(left), right)
      }
    _ -> Leaf
  }
}

fn move_red_left(tree: Tree(v)) -> Tree(v) {
  case tree {
    Node(
      _,
      k,
      v,
      Node(_, l_k, l_v, l_left, l_right),
      Node(_, r_k, r_v, Node(Red, rl_k, rl_v, rl_l, rl_r), r_right),
    ) ->
      Node(
        Red,
        rl_k,
        rl_v,
        Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), rl_l),
        Node(Black, r_k, r_v, rl_r, r_right),
      )
    Node(
      color,
      k,
      v,
      Node(_, l_k, l_v, l_left, l_right),
      Node(_, r_k, r_v, r_left, r_right),
    ) ->
      case color {
        Black ->
          Node(
            Black,
            k,
            v,
            Node(Red, l_k, l_v, l_left, l_right),
            Node(Red, r_k, r_v, r_left, r_right),
          )
        Red ->
          Node(
            Black,
            k,
            v,
            Node(Red, l_k, l_v, l_left, l_right),
            Node(Red, r_k, r_v, r_left, r_right),
          )
      }
    _ -> tree
  }
}

fn move_red_right(tree: Tree(v)) -> Tree(v) {
  case tree {
    Node(
      _,
      k,
      v,
      Node(_, l_k, l_v, Node(Red, ll_k, ll_v, ll_left, ll_right), l_right),
      Node(_, r_k, r_v, r_left, r_right),
    ) ->
      Node(
        Red,
        l_k,
        l_v,
        Node(Black, ll_k, ll_v, ll_left, ll_right),
        Node(Black, k, v, l_right, Node(Red, r_k, r_v, r_left, r_right)),
      )
    Node(
      color,
      k,
      v,
      Node(_, l_k, l_v, l_left, l_right),
      Node(_, r_k, r_v, r_left, r_right),
    ) ->
      case color {
        Black ->
          Node(
            Black,
            k,
            v,
            Node(Red, l_k, l_v, l_left, l_right),
            Node(Red, r_k, r_v, r_left, r_right),
          )
        Red ->
          Node(
            Black,
            k,
            v,
            Node(Red, l_k, l_v, l_left, l_right),
            Node(Red, r_k, r_v, r_left, r_right),
          )
      }
    _ -> tree
  }
}

// FOLDS AND TRANSFORMS

fn fold(tree: Tree(v), acc: b, func: fn(Int, v, b) -> b) -> b {
  case tree {
    Leaf -> acc
    Node(_, key, value, left, right) ->
      fold(right, func(key, value, fold(left, acc, func)), func)
  }
}

fn fold_right(tree: Tree(v), acc: b, func: fn(Int, v, b) -> b) -> b {
  case tree {
    Leaf -> acc
    Node(_, key, value, left, right) ->
      fold_right(left, func(key, value, fold_right(right, acc, func)), func)
  }
}

fn from_list(pairs: List(#(Int, v))) -> Tree(v) {
  list.fold(pairs, empty(), fn(tree, pair) { insert(tree, pair.0, pair.1) })
}

fn to_list(tree: Tree(v)) -> List(#(Int, v)) {
  fold_right(tree, [], fn(k, v, acc) { [#(k, v), ..acc] })
}

fn keys(tree: Tree(v)) -> List(Int) {
  fold_right(tree, [], fn(k, _, acc) { [k, ..acc] })
}

fn values(tree: Tree(v)) -> List(v) {
  fold_right(tree, [], fn(_, v, acc) { [v, ..acc] })
}

fn map(tree: Tree(a), func: fn(Int, a) -> b) -> Tree(b) {
  case tree {
    Leaf -> Leaf
    Node(color, key, value, left, right) ->
      Node(color, key, func(key, value), map(left, func), map(right, func))
  }
}

fn filter(tree: Tree(v), keep: fn(Int, v) -> Bool) -> Tree(v) {
  fold(tree, empty(), fn(k, v, acc) {
    case keep(k, v) {
      True -> insert(acc, k, v)
      False -> acc
    }
  })
}

fn union(preferred: Tree(v), other: Tree(v)) -> Tree(v) {
  fold(preferred, other, fn(k, v, acc) { insert(acc, k, v) })
}

fn height(tree: Tree(v)) -> Int {
  case tree {
    Leaf -> 0
    Node(_, _, _, left, right) -> 1 + int.max(height(left), height(right))
  }
}

// INVARIANTS

fn is_red(tree: Tree(v)) -> Bool {
  case tree {
    Node(Red, _, _, _, _) -> True
    _ -> False
  }
}

fn no_red_red(tree: Tree(v)) -> Bool {
  case tree {
    Leaf -> True
    Node(Red, _, _, left, right) ->
      !is_red(left) && !is_red(right) && no_red_red(left) && no_red_red(right)
    Node(Black, _, _, left, right) -> no_red_red(left) && no_red_red(right)
  }
}

fn black_height(tree: Tree(v)) -> Option(Int) {
  case tree {
    Leaf -> Some(1)
    Node(color, _, _, left, right) ->
      case black_height(left), black_height(right) {
        Some(l), Some(r) ->
          case l == r {
            True ->
              case color {
                Black -> Some(l + 1)
                Red -> Some(l)
              }
            False -> None
          }
        _, _ -> None
      }
  }
}

fn is_ordered(tree: Tree(v)) -> Bool {
  ascending(keys(tree))
}

fn ascending(xs: List(Int)) -> Bool {
  case xs {
    [a, b, ..rest] -> a < b && ascending([b, ..rest])
    _ -> True
  }
}

fn is_valid(tree: Tree(v)) -> Bool {
  !is_red(tree)
  && no_red_red(tree)
  && black_height(tree) != None
  && is_ordered(tree)
}

// DRIVER

fn pseudo_random(seed: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count == 0 {
    True -> list.reverse(acc)
    False -> {
      let next = { seed * 7919 + 13 } % 10_007
      pseudo_random(next, count - 1, [next % 1000, ..acc])
    }
  }
}

fn show_bool(b: Bool) -> String {
  case b {
    True -> "yes"
    False -> "no"
  }
}

fn show_ints(xs: List(Int)) -> String {
  string.join(list.map(xs, int.to_string), ",")
}

pub fn run() -> List(String) {
  let numbers = pseudo_random(42, 400, [])
  let tree =
    from_list(list.map(numbers, fn(n) { #(n, "v" <> int.to_string(n)) }))
  let removed =
    list.fold(list.filter(numbers, fn(n) { n % 3 == 0 }), tree, remove)
  let doubled = map(removed, fn(k, _) { k * 2 })
  let evens = filter(removed, fn(k, _) { k % 2 == 0 })
  let merged =
    union(from_list([#(1, "one"), #(2, "two"), #(5000, "big")]), removed)
  let key_sum = fold(removed, 0, fn(k, _, acc) { acc + k })
  let value_length =
    fold_right(removed, 0, fn(_, v, acc) { acc + string.length(v) })
  [
    "size "
      <> int.to_string(size(tree))
      <> " -> "
      <> int.to_string(size(removed)),
    "valid "
      <> show_bool(is_valid(tree))
      <> " "
      <> show_bool(is_valid(removed))
      <> " "
      <> show_bool(is_valid(evens))
      <> " "
      <> show_bool(is_valid(merged)),
    "height "
      <> int.to_string(height(tree))
      <> " "
      <> int.to_string(height(removed)),
    "first " <> show_ints(list.take(keys(removed), 12)),
    "sum " <> int.to_string(key_sum) <> " chars " <> int.to_string(value_length),
    "doubled " <> show_ints(list.take(values(doubled), 6)),
    "evens "
      <> int.to_string(size(evens))
      <> " merged "
      <> int.to_string(size(merged)),
    "lookup "
      <> option.unwrap(get(merged, 5000), "none")
      <> " "
      <> option.unwrap(get(removed, 3), "none")
      <> " "
      <> show_bool(member(merged, 1)),
    "pairs "
      <> string.join(
      list.map(list.take(to_list(merged), 4), fn(pair) {
        int.to_string(pair.0) <> "=" <> pair.1
      }),
      " ",
    ),
  ]
}
