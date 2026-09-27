module Tree exposing (run)

-- A left-leaning red-black tree keyed by Int: insert, remove, lookup,
-- folds, map/filter/union, and an invariant checker.


type Color
    = Red
    | Black


type Tree v
    = Leaf
    | Node Color Int v (Tree v) (Tree v)


empty : Tree v
empty =
    Leaf


get : Int -> Tree v -> Maybe v
get target tree =
    case tree of
        Leaf ->
            Nothing

        Node _ key value left right ->
            if target < key then
                get target left

            else if target > key then
                get target right

            else
                Just value


member : Int -> Tree v -> Bool
member target tree =
    case get target tree of
        Just _ ->
            True

        Nothing ->
            False


size : Tree v -> Int
size tree =
    case tree of
        Leaf ->
            0

        Node _ _ _ left right ->
            1 + size left + size right



-- INSERT


insert : Int -> v -> Tree v -> Tree v
insert key value tree =
    case insertHelp key value tree of
        Node Red k v l r ->
            Node Black k v l r

        other ->
            other


insertHelp : Int -> v -> Tree v -> Tree v
insertHelp key value tree =
    case tree of
        Leaf ->
            Node Red key value Leaf Leaf

        Node color nodeKey nodeValue left right ->
            if key < nodeKey then
                balance color nodeKey nodeValue (insertHelp key value left) right

            else if key > nodeKey then
                balance color nodeKey nodeValue left (insertHelp key value right)

            else
                Node color nodeKey value left right


balance : Color -> Int -> v -> Tree v -> Tree v -> Tree v
balance color key value left right =
    case right of
        Node Red rK rV rLeft rRight ->
            case left of
                Node Red lK lV lLeft lRight ->
                    Node Red key value (Node Black lK lV lLeft lRight) (Node Black rK rV rLeft rRight)

                _ ->
                    Node color rK rV (Node Red key value left rLeft) rRight

        _ ->
            case left of
                Node Red lK lV (Node Red llK llV llLeft llRight) lRight ->
                    Node Red lK lV (Node Black llK llV llLeft llRight) (Node Black key value lRight right)

                _ ->
                    Node color key value left right



-- REMOVE


remove : Int -> Tree v -> Tree v
remove key tree =
    case removeHelp key tree of
        Node Red k v l r ->
            Node Black k v l r

        other ->
            other


removeHelp : Int -> Tree v -> Tree v
removeHelp target tree =
    case tree of
        Leaf ->
            Leaf

        Node color key value left right ->
            if target < key then
                case left of
                    Node Black _ _ lLeft _ ->
                        case lLeft of
                            Node Red _ _ _ _ ->
                                Node color key value (removeHelp target left) right

                            _ ->
                                case moveRedLeft tree of
                                    Node nColor nKey nValue nLeft nRight ->
                                        balance nColor nKey nValue (removeHelp target nLeft) nRight

                                    Leaf ->
                                        Leaf

                    _ ->
                        Node color key value (removeHelp target left) right

            else
                removeHelpEQGT target (removeHelpPrepEQGT tree color key value left right)


removeHelpPrepEQGT : Tree v -> Color -> Int -> v -> Tree v -> Tree v -> Tree v
removeHelpPrepEQGT tree color key value left right =
    case left of
        Node Red lK lV lLeft lRight ->
            Node color lK lV lLeft (Node Red key value lRight right)

        _ ->
            case right of
                Node Black _ _ (Node Black _ _ _ _) _ ->
                    moveRedRight tree

                Node Black _ _ Leaf _ ->
                    moveRedRight tree

                _ ->
                    tree


removeHelpEQGT : Int -> Tree v -> Tree v
removeHelpEQGT target tree =
    case tree of
        Node color key value left right ->
            if target == key then
                case getMin right of
                    Node _ minKey minValue _ _ ->
                        balance color minKey minValue left (removeMin right)

                    Leaf ->
                        Leaf

            else
                balance color key value left (removeHelp target right)

        Leaf ->
            Leaf


getMin : Tree v -> Tree v
getMin tree =
    case tree of
        Node _ _ _ ((Node _ _ _ _ _) as left) _ ->
            getMin left

        _ ->
            tree


removeMin : Tree v -> Tree v
removeMin tree =
    case tree of
        Node color key value ((Node lColor _ _ lLeft _) as left) right ->
            case lColor of
                Black ->
                    case lLeft of
                        Node Red _ _ _ _ ->
                            Node color key value (removeMin left) right

                        _ ->
                            case moveRedLeft tree of
                                Node nColor nKey nValue nLeft nRight ->
                                    balance nColor nKey nValue (removeMin nLeft) nRight

                                Leaf ->
                                    Leaf

                Red ->
                    Node color key value (removeMin left) right

        _ ->
            Leaf


moveRedLeft : Tree v -> Tree v
moveRedLeft tree =
    case tree of
        Node _ k v (Node _ lK lV lLeft lRight) (Node _ rK rV (Node Red rlK rlV rlL rlR) rRight) ->
            Node Red rlK rlV (Node Black k v (Node Red lK lV lLeft lRight) rlL) (Node Black rK rV rlR rRight)

        Node color k v (Node _ lK lV lLeft lRight) (Node _ rK rV rLeft rRight) ->
            case color of
                Black ->
                    Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)

                Red ->
                    Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)

        _ ->
            tree


moveRedRight : Tree v -> Tree v
moveRedRight tree =
    case tree of
        Node _ k v (Node _ lK lV (Node Red llK llV llLeft llRight) lRight) (Node _ rK rV rLeft rRight) ->
            Node Red lK lV (Node Black llK llV llLeft llRight) (Node Black k v lRight (Node Red rK rV rLeft rRight))

        Node color k v (Node _ lK lV lLeft lRight) (Node _ rK rV rLeft rRight) ->
            case color of
                Black ->
                    Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)

                Red ->
                    Node Black k v (Node Red lK lV lLeft lRight) (Node Red rK rV rLeft rRight)

        _ ->
            tree



-- FOLDS AND TRANSFORMS


foldl : (Int -> v -> b -> b) -> b -> Tree v -> b
foldl func acc tree =
    case tree of
        Leaf ->
            acc

        Node _ key value left right ->
            foldl func (func key value (foldl func acc left)) right


foldr : (Int -> v -> b -> b) -> b -> Tree v -> b
foldr func acc tree =
    case tree of
        Leaf ->
            acc

        Node _ key value left right ->
            foldr func (func key value (foldr func acc right)) left


fromList : List ( Int, v ) -> Tree v
fromList pairs =
    List.foldl (\( k, v ) tree -> insert k v tree) empty pairs


toList : Tree v -> List ( Int, v )
toList tree =
    foldr (\k v acc -> ( k, v ) :: acc) [] tree


keys : Tree v -> List Int
keys tree =
    foldr (\k _ acc -> k :: acc) [] tree


values : Tree v -> List v
values tree =
    foldr (\_ v acc -> v :: acc) [] tree


map : (Int -> a -> b) -> Tree a -> Tree b
map func tree =
    case tree of
        Leaf ->
            Leaf

        Node color key value left right ->
            Node color key (func key value) (map func left) (map func right)


filter : (Int -> v -> Bool) -> Tree v -> Tree v
filter keep tree =
    foldl
        (\k v acc ->
            if keep k v then
                insert k v acc

            else
                acc
        )
        empty
        tree


union : Tree v -> Tree v -> Tree v
union preferred other =
    foldl (\k v acc -> insert k v acc) other preferred


height : Tree v -> Int
height tree =
    case tree of
        Leaf ->
            0

        Node _ _ _ left right ->
            1 + max (height left) (height right)



-- INVARIANTS


isRed : Tree v -> Bool
isRed tree =
    case tree of
        Node Red _ _ _ _ ->
            True

        _ ->
            False


noRedRed : Tree v -> Bool
noRedRed tree =
    case tree of
        Leaf ->
            True

        Node Red _ _ left right ->
            not (isRed left) && not (isRed right) && noRedRed left && noRedRed right

        Node Black _ _ left right ->
            noRedRed left && noRedRed right


blackHeight : Tree v -> Maybe Int
blackHeight tree =
    case tree of
        Leaf ->
            Just 1

        Node color _ _ left right ->
            case ( blackHeight left, blackHeight right ) of
                ( Just l, Just r ) ->
                    if l == r then
                        case color of
                            Black ->
                                Just (l + 1)

                            Red ->
                                Just l

                    else
                        Nothing

                _ ->
                    Nothing


isOrdered : Tree v -> Bool
isOrdered tree =
    ascending (keys tree)


ascending : List Int -> Bool
ascending xs =
    case xs of
        a :: b :: rest ->
            a < b && ascending (b :: rest)

        _ ->
            True


isValid : Tree v -> Bool
isValid tree =
    not (isRed tree) && noRedRed tree && blackHeight tree /= Nothing && isOrdered tree



-- DRIVER


pseudoRandom : Int -> Int -> List Int -> List Int
pseudoRandom seed count acc =
    if count == 0 then
        List.reverse acc

    else
        let
            next =
                remainderBy 10007 (seed * 7919 + 13)
        in
        pseudoRandom next (count - 1) (remainderBy 1000 next :: acc)


showBool : Bool -> String
showBool b =
    if b then
        "yes"

    else
        "no"


showInts : List Int -> String
showInts xs =
    String.join "," (List.map String.fromInt xs)


run : List String
run =
    let
        numbers =
            pseudoRandom 42 400 []

        tree =
            fromList (List.map (\n -> ( n, "v" ++ String.fromInt n )) numbers)

        removed =
            List.foldl remove tree (List.filter (\n -> remainderBy 3 n == 0) numbers)

        doubled =
            map (\k _ -> k * 2) removed

        evens =
            filter (\k _ -> remainderBy 2 k == 0) removed

        merged =
            union (fromList [ ( 1, "one" ), ( 2, "two" ), ( 5000, "big" ) ]) removed

        keySum =
            foldl (\k _ acc -> acc + k) 0 removed

        valueLength =
            foldr (\_ v acc -> acc + String.length v) 0 removed
    in
    [ "size " ++ String.fromInt (size tree) ++ " -> " ++ String.fromInt (size removed)
    , "valid " ++ showBool (isValid tree) ++ " " ++ showBool (isValid removed) ++ " " ++ showBool (isValid evens) ++ " " ++ showBool (isValid merged)
    , "height " ++ String.fromInt (height tree) ++ " " ++ String.fromInt (height removed)
    , "first " ++ showInts (List.take 12 (keys removed))
    , "sum " ++ String.fromInt keySum ++ " chars " ++ String.fromInt valueLength
    , "doubled " ++ showInts (List.take 6 (values doubled))
    , "evens " ++ String.fromInt (size evens) ++ " merged " ++ String.fromInt (size merged)
    , "lookup " ++ Maybe.withDefault "none" (get 5000 merged) ++ " " ++ Maybe.withDefault "none" (get 3 removed) ++ " " ++ showBool (member 1 merged)
    , "pairs " ++ String.join " " (List.map (\( k, v ) -> String.fromInt k ++ "=" ++ v) (List.take 4 (toList merged)))
    ]
