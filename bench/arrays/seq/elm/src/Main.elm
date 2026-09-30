port module Main exposing (main)

import Array exposing (Array)

port out : Int -> Cmd msg

keep : Array Int -> Int
keep a =
    let
        b = Array.push 1 (Array.set 0 2 a)
        c = Array.append (Array.slice 1 3 b) (Array.map (\x -> x + 1) b)
        d = Array.filter (\x -> x > 1) c
        e = Array.fromList (Array.toList d)
        f = Array.foldl (+) 0 e + Array.foldr (+) 0 e
        g = Array.toIndexedList (Array.indexedMap (+) (Array.initialize 3 identity))
    in
    f + Array.length e + Maybe.withDefault 0 (Array.get 0 e) + List.length g + (if Array.isEmpty (Array.repeat 2 0) then 1 else 0)

main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), out (keep Array.empty) )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
