module Tree (run) where

-- A left-leaning red-black tree keyed by Int: insert, remove, lookup,
-- folds, map/filter/union, and an invariant checker.

import Prelude

import Data.Foldable (foldl)
import Data.List (List(..), filter, fromFoldable, reverse, take, (:))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith, length)
import Data.Array as Array
import Data.Tuple (Tuple(..))

data Color
  = Red
  | Black

data Tree v
  = Leaf
  | Node Color Int v (Tree v) (Tree v)

empty :: forall v. Tree v
empty = Leaf

get :: forall v. Int -> Tree v -> Maybe v
get target tree = case tree of
  Leaf -> Nothing
  Node _ key value left right ->
    if target < key then
      get target left
    else if target > key then
      get target right
    else
      Just value

member :: forall v. Int -> Tree v -> Boolean
member target tree = case get target tree of
  Just _ -> true
  Nothing -> false

size :: forall v. Tree v -> Int
size tree = case tree of
  Leaf -> 0
  Node _ _ _ left right -> 1 + size left + size right

-- INSERT

insert :: forall v. Int -> v -> Tree v -> Tree v
insert key value tree = case insertHelp key value tree of
  Node Red k v l r -> Node Black k v l r
  other -> other

insertHelp :: forall v. Int -> v -> Tree v -> Tree v
insertHelp key value tree = case tree of
  Leaf -> Node Red key value Leaf Leaf
  Node color nodeKey nodeValue left right ->
    if key < nodeKey then
      balance color nodeKey nodeValue (insertHelp key value left) right
    else if key > nodeKey then
      balance color nodeKey nodeValue left (insertHelp key value right)
    else
      Node color nodeKey value left right

balance :: forall v. Color -> Int -> v -> Tree v -> Tree v -> Tree v
balance color key value left right = case right of
  Node Red rK rV rLeft rRight -> case left of
    Node Red lK lV lLeft lRight ->
      Node Red key value (Node Black lK lV lLeft lRight) (Node Black rK rV rLeft rRight)
    _ ->
      Node color rK rV (Node Red key value left rLeft) rRight
  _ -> case left of
    Node Red lK lV (Node Red llK llV llLeft llRight) lRight ->
      Node Red lK lV (Node Black llK llV llLeft llRight) (Node Black key value lRight right)
    _ ->
      Node color key value left right

-- REMOVE

remove :: forall v. Int -> Tree v -> Tree v
remove key tree = case removeHelp key tree of
  Node Red k v l r -> Node Black k v l r
  other -> other

removeHelp :: forall v. Int -> Tree v -> Tree v
removeHelp target tree = case tree of
  Leaf -> Leaf
  Node color key value left right ->
    if target < key then
      case left of
        Node Black _ _ lLeft _ -> case lLeft of
          Node Red _ _ _ _ ->
            Node color key value (removeHelp target left) right
          _ -> case moveRedLeft tree of
            Node nColor nKey nValue nLeft nRight ->
              balance nColor nKey nValue (removeHelp target nLeft) nRight
            Leaf -> Leaf
        _ ->
          Node color key value (removeHelp target left) right
    else
      removeHelpEQGT target (removeHelpPrepEQGT tree color key value left right)

removeHelpPrepEQGT :: forall v. Tree v -> Color -> Int -> v -> Tree v -> Tree v -> Tree v
removeHelpPrepEQGT tree color key value left right = case left of
  Node Red lK lV lLeft lRight ->
    Node color lK lV lLeft (Node Red key value lRight right)
  _ -> case right of
    Node Black _ _ (Node Black _ _ _ _) _ -> moveRedRight tree
    Node Black _ _ Leaf _ -> moveRedRight tree
    _ -> tree

removeHelpEQGT :: forall v. Int -> Tree v -> Tree v
removeHelpEQGT target tree = case tree of
  Node color key value left right ->
    if target == key then
      case getMin right of
        Node _ minKey minValue _ _ ->
          balance color minKey minValue left (removeMin right)
        Leaf -> Leaf
    else
      balance color key value left (removeHelp target right)
  Leaf -> Leaf

getMin :: forall v. Tree v -> Tree v
getMin tree = case tree of
  Node _ _ _ left@(Node _ _ _ _ _) _ -> getMin left
  _ -> tree

removeMin :: forall v. Tree v -> Tree v
removeMin tree = case tree of
  Node color key value left@(Node lColor _ _ lLeft _) right -> case lColor of
    Black -> case lLeft of
      Node Red _ _ _ _ ->
        Node color key value (removeMin left) right
      _ -> case moveRedLeft tree of
        Node nColor nKey nValue nLeft nRight ->
          balance nColor nKey nValue (removeMin nLeft) nRight
        Leaf -> Leaf
    Red ->
      Node color key value (removeMin left) right
  _ -> Leaf

moveRedLeft :: forall v. Tree v -> Tree v
moveRedLeft tree = case tree of
  Node _ k v (Node _ lK lV lLeft lRight) (Node _ rK rV (Node Red rlK rlV rlL rlR) rRight) ->
    Node Red rlK rlV (Node Black k v (Node Red lK lV lLeft lRight) rlL) (Node Black rK rV rlR rRight)
  Node color k v (Node _ lK lV lLeft lRight) (Node _ rK rV rLeft rRight) -> case color of
    Black ->
      Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)
    Red ->
      Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)
  _ -> tree

moveRedRight :: forall v. Tree v -> Tree v
moveRedRight tree = case tree of
  Node _ k v (Node _ lK lV (Node Red llK llV llLeft llRight) lRight) (Node _ rK rV rLeft rRight) ->
    Node Red lK lV (Node Black llK llV llLeft llRight) (Node Black k v lRight (Node Red rK rV rLeft rRight))
  Node color k v (Node _ lK lV lLeft lRight) (Node _ rK rV rLeft rRight) -> case color of
    Black ->
      Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)
    Red ->
      Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)
  _ -> tree

-- FOLDS AND TRANSFORMS

foldlTree :: forall v b. (Int -> v -> b -> b) -> b -> Tree v -> b
foldlTree func acc tree = case tree of
  Leaf -> acc
  Node _ key value left right ->
    foldlTree func (func key value (foldlTree func acc left)) right

foldrTree :: forall v b. (Int -> v -> b -> b) -> b -> Tree v -> b
foldrTree func acc tree = case tree of
  Leaf -> acc
  Node _ key value left right ->
    foldrTree func (func key value (foldrTree func acc right)) left

fromList :: forall v. List (Tuple Int v) -> Tree v
fromList pairs = foldl (\tree (Tuple k v) -> insert k v tree) empty pairs

toList :: forall v. Tree v -> List (Tuple Int v)
toList tree = foldrTree (\k v acc -> Tuple k v : acc) Nil tree

keys :: forall v. Tree v -> List Int
keys tree = foldrTree (\k _ acc -> k : acc) Nil tree

values :: forall v. Tree v -> List v
values tree = foldrTree (\_ v acc -> v : acc) Nil tree

mapTree :: forall a b. (Int -> a -> b) -> Tree a -> Tree b
mapTree func tree = case tree of
  Leaf -> Leaf
  Node color key value left right ->
    Node color key (func key value) (mapTree func left) (mapTree func right)

filterTree :: forall v. (Int -> v -> Boolean) -> Tree v -> Tree v
filterTree keep tree =
  foldlTree
    ( \k v acc ->
        if keep k v then
          insert k v acc
        else
          acc
    )
    empty
    tree

union :: forall v. Tree v -> Tree v -> Tree v
union preferred other = foldlTree (\k v acc -> insert k v acc) other preferred

height :: forall v. Tree v -> Int
height tree = case tree of
  Leaf -> 0
  Node _ _ _ left right -> 1 + max (height left) (height right)

-- INVARIANTS

isRed :: forall v. Tree v -> Boolean
isRed tree = case tree of
  Node Red _ _ _ _ -> true
  _ -> false

noRedRed :: forall v. Tree v -> Boolean
noRedRed tree = case tree of
  Leaf -> true
  Node Red _ _ left right ->
    not (isRed left) && not (isRed right) && noRedRed left && noRedRed right
  Node Black _ _ left right ->
    noRedRed left && noRedRed right

blackHeight :: forall v. Tree v -> Maybe Int
blackHeight tree = case tree of
  Leaf -> Just 1
  Node color _ _ left right -> case blackHeight left, blackHeight right of
    Just l, Just r ->
      if l == r then
        case color of
          Black -> Just (l + 1)
          Red -> Just l
      else
        Nothing
    _, _ -> Nothing

isOrdered :: forall v. Tree v -> Boolean
isOrdered tree = ascending (keys tree)

ascending :: List Int -> Boolean
ascending xs = case xs of
  a : b : rest -> a < b && ascending (b : rest)
  _ -> true

isValid :: forall v. Tree v -> Boolean
isValid tree = not (isRed tree) && noRedRed tree && blackHeight tree /= Nothing && isOrdered tree

-- DRIVER

pseudoRandom :: Int -> Int -> List Int -> List Int
pseudoRandom seed count acc =
  if count == 0 then
    reverse acc
  else
    let
      next = (seed * 7919 + 13) `mod` 10007
    in
      pseudoRandom next (count - 1) (next `mod` 1000 : acc)

showBool :: Boolean -> String
showBool b = if b then "yes" else "no"

showInts :: List Int -> String
showInts xs = joinWith "," (Array.fromFoldable (map show xs))

run :: List String
run =
  let
    numbers = pseudoRandom 42 400 Nil
    tree = fromList (map (\n -> Tuple n ("v" <> show n)) numbers)
    removed = foldl (\acc n -> remove n acc) tree (filter (\n -> n `mod` 3 == 0) numbers)
    doubled = mapTree (\k _ -> k * 2) removed
    evens = filterTree (\k _ -> k `mod` 2 == 0) removed
    merged = union (fromList (fromFoldable [ Tuple 1 "one", Tuple 2 "two", Tuple 5000 "big" ])) removed
    keySum = foldlTree (\k _ acc -> acc + k) 0 removed
    valueLength = foldrTree (\_ v acc -> acc + length v) 0 removed
  in
    fromFoldable
      [ "size " <> show (size tree) <> " -> " <> show (size removed)
      , "valid " <> showBool (isValid tree) <> " " <> showBool (isValid removed) <> " " <> showBool (isValid evens) <> " " <> showBool (isValid merged)
      , "height " <> show (height tree) <> " " <> show (height removed)
      , "first " <> showInts (take 12 (keys removed))
      , "sum " <> show keySum <> " chars " <> show valueLength
      , "doubled " <> showInts (take 6 (values doubled))
      , "evens " <> show (size evens) <> " merged " <> show (size merged)
      , "lookup " <> fromMaybe "none" (get 5000 merged) <> " " <> fromMaybe "none" (get 3 removed) <> " " <> showBool (member 1 merged)
      , "pairs " <> joinWith " " (Array.fromFoldable (map (\(Tuple k v) -> show k <> "=" <> v) (take 4 (toList merged))))
      ]
