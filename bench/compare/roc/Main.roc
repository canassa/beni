module [results]

import Data
import Interp
import Tree

results : List Str
results = List.join([Interp.run, Tree.run, Data.run])
