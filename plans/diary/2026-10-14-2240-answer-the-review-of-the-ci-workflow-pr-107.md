## 2026-10-14 22:40 CEST — answer the review of the CI workflow (PR #107)

**What I did**

Recorded who decided that CI runs with no budget. Jayson Reis decided it on
2026-10-14 at 17:36 UTC. Cesar Canassa, the repository owner, agreed in a
note at 17:34 UTC: "cancel the self-hosted solution. disable the CPU counter
in the CI". My entry above says only "the owner's decision". Then I answered
the review. The workflow downloads `nix-installer` v3.23.2 from its GitHub
release, checks it against the release's SHA-256, and gives it to the
action. A master run removes a restored Zig cache over 3 GiB; a pull request
keeps what it restores. The Nix store is saved only after the dev shell
comes up, with a 2 GiB bound, and a profile roots the shell's closure.
Rebased onto master after #96, #97 and #106.

**What I learned**

My entry above says that only a push to master saves a cache. That was
false: the installer action cached its own binary, 46 MiB, in each pull
request's scope. Given a binary, it caches nothing. Its `source-tag` pin
with `source-checksums-url` needs a checksums file, and the installer's
releases publish none. A pull request's cache scope cannot change what
master restores. A `claude.yml` job runs in master's scope and can.
`nix develop --profile` makes the shell's closure a garbage-collector root;
without one, `gc-max-store-size` can remove the toolchain.
