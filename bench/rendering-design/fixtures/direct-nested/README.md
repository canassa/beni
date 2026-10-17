# Direct nested-helper reproducer (#189)

These are exact generated source snapshots, archived with `.txt` suffixes so
repository formatting does not rewrite the measured inputs. Copy `Main.beni.txt`
and `Shape0.beni.txt` into a temporary package directory, dropping `.txt`, then:

```sh
beni build --platform=browser-direct --release --out=/tmp/nested-output /tmp/nested-source
```

Load the emitted `_main.mjs` in a page, then click the first “Child action” button.
Direct throws its undeclared-template-fallback visit invariant. The tea build
updates both the total and nested counter. The campaign's `nested-17-1` case
regenerates these same source files and preserves the failure in its results.
