# Ownership words

Core and platform packages tell the ownership checker what a `foreign` or a
representation function does with its arguments. The words go in front of a
parameter's type or the result's type. The ownership checker v2 reads more
words than v1:

- on a parameter: `written`, `stored`, `cellread`, `cellwrite`, `cellstored`,
  `cellupdate`, `cellmodify`, `cellcomplete`;
- on a function parameter or the result: `taken`;
- on the result: `lent`, `lentoptional`, `cellnew`, `cellempty`,
  `builderdone`, `concatenated`;
- before a type declaration: `sequence` (a unary `foreign type`), `cell` (a
  unary opaque `type` or `foreign type`), `sender` (an alias of a function of
  one argument that returns `⊤`);
- before one of the two unary constructors of a type: `failure`.

Some words fix the role of another parameter. For example, `cellwrite` needs
a second parameter that is `cellstored`, `cellupdate` or `cellmodify`, and
`cellupdate` needs a `sync` function. The words do not change a type or the
emitted code. Other packages cannot use them. A word in another package, at
an incorrect position, or without its companion word causes
`misplaced_ownership_word`.

```beni refused=misplaced_ownership_word
pub keep : stored Int → List Int
keep n = [ n ]
```

Source: `docs/design/language.md` §5.4, §10; `docs/design/ownership-v2.md` §2.13.5, §2.13.6.
