## 2026-10-29 21:55 CET — Io.readDir for node

**What I did.** Specified `Io.readDir` (transparent-effects-proposal §16.5 amendment; prerender §8.3/§8.11
notes) and built it in `platforms/node/Io.beni` and `Io.js`: `String → Result FileError (List Entry)`,
`Entry = { name, kind }`, `EntryKind = File | Directory | Symlink | Other`, entries sorted by the bytes of the
UTF-8 name, links not followed, each documented `readdir` failure one `FileError` constructor, anything else
re-thrown. Fixtures `run/ReadDir`, `ReadDirErrors`, `ReadDirFaults`, `ReadDirDefect`; `skills/beni/` updated.

**What I learned.** Constructors of a module share one namespace, so a separate `DirError` cannot reuse
`NotFound`; the list reuses `FileError`, whose `IsADirectory` and `TooLarge` never occur. A corpus run copies
only the `.beni` files of a fixture, so a directory tree needs a test platform that writes it (`Tree`).
`fs.promises.readdir` takes no `AbortSignal`: a cancelled fiber ignores the late answer.
