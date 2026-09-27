module [run]

# A left-leaning red-black tree keyed by I64: insert, remove, lookup,
# folds, map/filter/union, and an invariant checker.

Color : [Red, Black]

Tree v : [Leaf, Node Color I64 v (Tree v) (Tree v)]

empty : {} -> Tree v
empty = |{}| Leaf

get : Tree v, I64 -> Result v [NotFound]
get = |tree, target|
    when tree is
        Leaf -> Err(NotFound)
        Node(_, key, value, left, right) ->
            if target < key then
                get(left, target)
            else if target > key then
                get(right, target)
            else
                Ok(value)

member : Tree v, I64 -> Bool
member = |tree, target|
    when get(tree, target) is
        Ok(_) -> Bool.true
        Err(_) -> Bool.false

size : Tree v -> I64
size = |tree|
    when tree is
        Leaf -> 0
        Node(_, _, _, left, right) -> 1 + size(left) + size(right)

# INSERT

insert : Tree v, I64, v -> Tree v
insert = |tree, key, value|
    when insert_help(key, value, tree) is
        Node(Red, k, v, l, r) -> Node(Black, k, v, l, r)
        other -> other

insert_help : I64, v, Tree v -> Tree v
insert_help = |key, value, tree|
    when tree is
        Leaf -> Node(Red, key, value, Leaf, Leaf)
        Node(color, node_key, node_value, left, right) ->
            if key < node_key then
                balance(color, node_key, node_value, insert_help(key, value, left), right)
            else if key > node_key then
                balance(color, node_key, node_value, left, insert_help(key, value, right))
            else
                Node(color, node_key, value, left, right)

balance : Color, I64, v, Tree v, Tree v -> Tree v
balance = |color, key, value, left, right|
    when right is
        Node(Red, r_k, r_v, r_left, r_right) ->
            when left is
                Node(Red, l_k, l_v, l_left, l_right) ->
                    Node(Red, key, value, Node(Black, l_k, l_v, l_left, l_right), Node(Black, r_k, r_v, r_left, r_right))

                _ ->
                    Node(color, r_k, r_v, Node(Red, key, value, left, r_left), r_right)

        _ ->
            when left is
                Node(Red, l_k, l_v, Node(Red, ll_k, ll_v, ll_left, ll_right), l_right) ->
                    Node(Red, l_k, l_v, Node(Black, ll_k, ll_v, ll_left, ll_right), Node(Black, key, value, l_right, right))

                _ ->
                    Node(color, key, value, left, right)

# REMOVE

remove : Tree v, I64 -> Tree v
remove = |tree, key|
    when remove_help(key, tree) is
        Node(Red, k, v, l, r) -> Node(Black, k, v, l, r)
        other -> other

remove_help : I64, Tree v -> Tree v
remove_help = |target, tree|
    when tree is
        Leaf -> Leaf
        Node(color, key, value, left, right) ->
            if target < key then
                when left is
                    Node(Black, _, _, l_left, _) ->
                        when l_left is
                            Node(Red, _, _, _, _) ->
                                Node(color, key, value, remove_help(target, left), right)

                            _ ->
                                when move_red_left(tree) is
                                    Node(n_color, n_key, n_value, n_left, n_right) ->
                                        balance(n_color, n_key, n_value, remove_help(target, n_left), n_right)

                                    Leaf -> Leaf

                    _ ->
                        Node(color, key, value, remove_help(target, left), right)
            else
                remove_help_eq_gt(target, remove_help_prep_eq_gt(tree, color, key, value, left, right))

remove_help_prep_eq_gt : Tree v, Color, I64, v, Tree v, Tree v -> Tree v
remove_help_prep_eq_gt = |tree, color, key, value, left, right|
    when left is
        Node(Red, l_k, l_v, l_left, l_right) ->
            Node(color, l_k, l_v, l_left, Node(Red, key, value, l_right, right))

        _ ->
            when right is
                Node(Black, _, _, Node(Black, _, _, _, _), _) -> move_red_right(tree)
                Node(Black, _, _, Leaf, _) -> move_red_right(tree)
                _ -> tree

remove_help_eq_gt : I64, Tree v -> Tree v
remove_help_eq_gt = |target, tree|
    when tree is
        Node(color, key, value, left, right) ->
            if target == key then
                when get_min(right) is
                    Node(_, min_key, min_value, _, _) ->
                        balance(color, min_key, min_value, left, remove_min(right))

                    Leaf -> Leaf
            else
                balance(color, key, value, left, remove_help(target, right))

        Leaf -> Leaf

get_min : Tree v -> Tree v
get_min = |tree|
    when tree is
        Node(_, _, _, (Node(_, _, _, _, _) as left), _) -> get_min(left)
        _ -> tree

remove_min : Tree v -> Tree v
remove_min = |tree|
    when tree is
        Node(color, key, value, (Node(l_color, _, _, l_left, _) as left), right) ->
            when l_color is
                Black ->
                    when l_left is
                        Node(Red, _, _, _, _) ->
                            Node(color, key, value, remove_min(left), right)

                        _ ->
                            when move_red_left(tree) is
                                Node(n_color, n_key, n_value, n_left, n_right) ->
                                    balance(n_color, n_key, n_value, remove_min(n_left), n_right)

                                Leaf -> Leaf

                Red ->
                    Node(color, key, value, remove_min(left), right)

        _ -> Leaf

move_red_left : Tree v -> Tree v
move_red_left = |tree|
    when tree is
        Node(_, k, v, Node(_, l_k, l_v, l_left, l_right), Node(_, r_k, r_v, Node(Red, rl_k, rl_v, rl_l, rl_r), r_right)) ->
            Node(Red, rl_k, rl_v, Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), rl_l), Node(Black, r_k, r_v, rl_r, r_right))

        Node(color, k, v, Node(_, l_k, l_v, l_left, l_right), Node(_, r_k, r_v, r_left, r_right)) ->
            when color is
                Black ->
                    Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), Node(Red, r_k, r_v, r_left, r_right))

                Red ->
                    Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), Node(Red, r_k, r_v, r_left, r_right))

        _ -> tree

move_red_right : Tree v -> Tree v
move_red_right = |tree|
    when tree is
        Node(_, k, v, Node(_, l_k, l_v, Node(Red, ll_k, ll_v, ll_left, ll_right), l_right), Node(_, r_k, r_v, r_left, r_right)) ->
            Node(Red, l_k, l_v, Node(Black, ll_k, ll_v, ll_left, ll_right), Node(Black, k, v, l_right, Node(Red, r_k, r_v, r_left, r_right)))

        Node(color, k, v, Node(_, l_k, l_v, l_left, l_right), Node(_, r_k, r_v, r_left, r_right)) ->
            when color is
                Black ->
                    Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), Node(Red, r_k, r_v, r_left, r_right))

                Red ->
                    Node(Black, k, v, Node(Red, l_k, l_v, l_left, l_right), Node(Red, r_k, r_v, r_left, r_right))

        _ -> tree

# FOLDS AND TRANSFORMS

walk : Tree v, b, (I64, v, b -> b) -> b
walk = |tree, acc, func|
    when tree is
        Leaf -> acc
        Node(_, key, value, left, right) ->
            walk(right, func(key, value, walk(left, acc, func)), func)

walk_backwards : Tree v, b, (I64, v, b -> b) -> b
walk_backwards = |tree, acc, func|
    when tree is
        Leaf -> acc
        Node(_, key, value, left, right) ->
            walk_backwards(left, func(key, value, walk_backwards(right, acc, func)), func)

from_list : List (I64, v) -> Tree v
from_list = |pairs|
    List.walk(pairs, empty({}), |tree, (k, v)| insert(tree, k, v))

to_list : Tree v -> List (I64, v)
to_list = |tree|
    walk_backwards(tree, [], |k, v, acc| List.prepend(acc, (k, v)))

keys : Tree v -> List I64
keys = |tree|
    walk_backwards(tree, [], |k, _, acc| List.prepend(acc, k))

values : Tree v -> List v
values = |tree|
    walk_backwards(tree, [], |_, v, acc| List.prepend(acc, v))

map : Tree a, (I64, a -> b) -> Tree b
map = |tree, func|
    when tree is
        Leaf -> Leaf
        Node(color, key, value, left, right) ->
            Node(color, key, func(key, value), map(left, func), map(right, func))

keep_if : Tree v, (I64, v -> Bool) -> Tree v
keep_if = |tree, keep|
    walk(
        tree,
        empty({}),
        |k, v, acc|
            if keep(k, v) then
                insert(acc, k, v)
            else
                acc,
    )

union : Tree v, Tree v -> Tree v
union = |preferred, other|
    walk(preferred, other, |k, v, acc| insert(acc, k, v))

height : Tree v -> I64
height = |tree|
    when tree is
        Leaf -> 0
        Node(_, _, _, left, right) -> 1 + Num.max(height(left), height(right))

# INVARIANTS

is_red : Tree v -> Bool
is_red = |tree|
    when tree is
        Node(Red, _, _, _, _) -> Bool.true
        _ -> Bool.false

no_red_red : Tree v -> Bool
no_red_red = |tree|
    when tree is
        Leaf -> Bool.true
        Node(Red, _, _, left, right) ->
            !is_red(left) and !is_red(right) and no_red_red(left) and no_red_red(right)

        Node(Black, _, _, left, right) ->
            no_red_red(left) and no_red_red(right)

black_height : Tree v -> Result I64 [Unbalanced]
black_height = |tree|
    when tree is
        Leaf -> Ok(1)
        Node(color, _, _, left, right) ->
            when (black_height(left), black_height(right)) is
                (Ok(l), Ok(r)) ->
                    if l == r then
                        when color is
                            Black -> Ok(l + 1)
                            Red -> Ok(l)
                    else
                        Err(Unbalanced)

                _ -> Err(Unbalanced)

is_ordered : Tree v -> Bool
is_ordered = |tree|
    ascending(keys(tree))

ascending : List I64 -> Bool
ascending = |xs|
    when xs is
        [a, b, .. as rest] -> a < b and ascending(List.prepend(rest, b))
        _ -> Bool.true

is_valid : Tree v -> Bool
is_valid = |tree|
    balanced =
        when black_height(tree) is
            Ok(_) -> Bool.true
            Err(_) -> Bool.false
    !is_red(tree) and no_red_red(tree) and balanced and is_ordered(tree)

# DRIVER

pseudo_random : I64, I64, List I64 -> List I64
pseudo_random = |seed, count, acc|
    if count == 0 then
        List.reverse(acc)
    else
        next = (seed * 7919 + 13) % 10007
        pseudo_random(next, count - 1, List.prepend(acc, next % 1000))

show_bool : Bool -> Str
show_bool = |b| if b then "yes" else "no"

show_ints : List I64 -> Str
show_ints = |xs|
    Str.join_with(List.map(xs, Num.to_str), ",")

run : List Str
run =
    numbers = pseudo_random(42, 400, [])
    tree = from_list(List.map(numbers, |n| (n, "v${Num.to_str(n)}")))
    removed = List.walk(List.keep_if(numbers, |n| n % 3 == 0), tree, remove)
    doubled = map(removed, |k, _| k * 2)
    evens = keep_if(removed, |k, _| k % 2 == 0)
    merged = union(from_list([(1, "one"), (2, "two"), (5000, "big")]), removed)
    key_sum = walk(removed, 0, |k, _, acc| acc + k)
    value_length = walk_backwards(removed, 0, |_, v, acc| acc + Num.to_i64(Str.count_utf8_bytes(v)))
    pairs = List.map(List.take_first(to_list(merged), 4), |(k, v)| "${Num.to_str(k)}=${v}")
    [
        "size ${Num.to_str(size(tree))} -> ${Num.to_str(size(removed))}",
        "valid ${show_bool(is_valid(tree))} ${show_bool(is_valid(removed))} ${show_bool(is_valid(evens))} ${show_bool(is_valid(merged))}",
        "height ${Num.to_str(height(tree))} ${Num.to_str(height(removed))}",
        "first ${show_ints(List.take_first(keys(removed), 12))}",
        "sum ${Num.to_str(key_sum)} chars ${Num.to_str(value_length)}",
        "doubled ${show_ints(List.take_first(values(doubled), 6))}",
        "evens ${Num.to_str(size(evens))} merged ${Num.to_str(size(merged))}",
        "lookup ${Result.with_default(get(merged, 5000), "none")} ${Result.with_default(get(removed, 3), "none")} ${show_bool(member(merged, 1))}",
        "pairs ${Str.join_with(pairs, " ")}",
    ]
