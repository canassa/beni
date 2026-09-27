app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br" }

import pf.Stdout
import Main

main! = |_args|
    Stdout.line!(Str.join_with(Main.results, "\n"))
