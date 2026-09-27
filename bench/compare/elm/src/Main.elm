port module Main exposing (main)

import Data
import Interp
import Tree


port output : String -> Cmd msg


results : List String
results =
    List.concat [ Interp.run, Tree.run, Data.run ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), output (String.join "\n" results) )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
