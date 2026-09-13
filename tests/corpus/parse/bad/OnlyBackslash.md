`OnlyBackslash.beni` is a single `\` byte and a newline: a lambda backslash at
column 1, which cannot begin a declaration (`expected_declaration` at 1:1).
The file cannot hold a comment without changing what it tests.
