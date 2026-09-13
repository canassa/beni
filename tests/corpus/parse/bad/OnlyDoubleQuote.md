`OnlyDoubleQuote.beni` is a single `"` byte and a newline: an unterminated
string at 1:1 (`unterminated_string`), reported at the newline or EOF. It is
also not a declaration start (a column-1 token that cannot begin a
declaration may add `expected_declaration`). The file cannot hold a comment
without changing what it tests, hence this note.
