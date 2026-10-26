# Ownership words and the raise attribute

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


## Raise the ownership summary size

The ownership checker v2 builds a summary for each top-level value, with a
limit of 65536 growth records for each. The attribute raises that limit.
Any package can write it.

- `@ownership_summary_size(n)` on the line directly before a top-level
  value's annotation, or its definition when it has no annotation, raises
  the limit for that value. Comments can go between the two lines.
- `@ownership_summary_size(module, n)` before the first import raises the
  limit for every value of the module.

`n` is a decimal integer. It is at least the limit it raises and at most
4294967294. The attribute does not change a type or the emitted code, and
it does not let the checker accept a write without proof.

```beni
@ownership_summary_size(131072)
pub large : ⊤ → List Int
large ⊤ = [ 1, 2, 3 ]
```

A value below the limit, another attribute name, an attribute on a type,
or an attribute with no value after it causes `invalid_ownership_summary_size`.

```beni refused=invalid_ownership_summary_size
@ownership_summary_size(100)
pub small : List Int
small = [ 1 ]
```

Source: `docs/design/language.md` §5.4, §9, §10; `docs/design/ownership-v2.md` §2.13.5, §2.13.6, §4.4.
