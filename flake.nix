{
  description = "beni — an Elm-like language that compiles to JavaScript";

  # Pinned to the same channel as the host (/etc/nixos). Zig releases move the
  # std API, so the toolchain is upgraded deliberately. Never track unstable here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.zig-overlay.url = "github:mitchellh/zig-overlay";
  inputs.zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

  # The compilers under test in bench/compare (docs/design/compare-bench.md
  # §8.1): a separate, unstable pin, so upgrading Elm, Gleam, Roc, PureScript
  # or TypeScript never moves the compiler's own toolchain. Bump it alone to
  # re-measure against newer compilers; the results file records the rev.
  inputs.nixpkgs-compare.url = "github:NixOS/nixpkgs/b1b875982b17dabde9b4a37f3e229e74913e6db3";

  outputs = { self, nixpkgs, nixpkgs-compare, zig-overlay }:
    let
      # The shell is the same on every machine the compiler is developed on;
      # only the nixpkgs instance differs. Naming one system here was enough
      # until the first non-NixOS checkout, which then got no devShell at all.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # The Chromium of `nix develop .#browser`. nixpkgs' wrapper puts the
      # caller's LD_LIBRARY_PATH in front of the libraries Chromium links.
      # Where the login environment points that at an alsa-lib built for a
      # newer glibc than the flake's, Chromium stopped before `main` and
      # `test-browser` ran in the host's Chrome through `-Dchrome=`
      # (bench/ui/results/2026-10-08-scaling.md). This one unsets
      # LD_LIBRARY_PATH first, so a host library directory there cannot
      # stop it unless the directory holds glibc's own libraries: those
      # stop this script's bash, and `node`, before any wrapper runs.
      # It also drops entries set on purpose, such as a GPU driver
      # directory: `test-browser` starts Chrome with `--disable-gpu`
      # (tests/blackbox/browser.zig), so it needs none.
      # `checks.browser-chromium` runs the shell's `chromium` against it.
      browserChromium = pkgs: pkgs.writeShellScriptBin "chromium" ''
        unset LD_LIBRARY_PATH
        exec ${pkgs.chromium}/bin/chromium "$@"
      '';

      # Zig has two caches. The LOCAL one, `.zig-cache`, holds what a build
      # compiles from the worktree's files, and each worktree keeps its own:
      # its manifests name files relative to the build root, so a shared one
      # handed a worktree a binary built from another worktree's sources
      # (commit bfc234325). The GLOBAL one holds the build runner,
      # compiler-rt, the ZIR of Zig's library, the generated `builtin.zig`
      # of each module and fetched packages by their hash, with every
      # input file named relative to Zig's library or the global cache
      # itself. That stays true only while no build step puts a file of
      # the worktree into the global cache. In Zig 0.17 a step names a
      # path there with the base `.global_cache`, as in
      # `b.graph.path(.global_cache, …)`. beni's build has no such path,
      # and it must not get one that holds a file of the worktree.
      # `git grep global_cache -- '*.zig'` finds that name. A path made in
      # another way needs a reviewer's eye.
      # One global cache serves every worktree of beni and no other
      # project. In the default `~/.cache/zig`, another project's Nix
      # build of Zig 0.17.0 took the slots of the build runner and
      # compiler-rt: its library differs in one file and its version
      # string does not, so each Zig evicted the other's entries, and the
      # next `zig build` here compiled them again for 1 to 3 minutes
      # (#145, #161). A ZIG_GLOBAL_CACHE_DIR that the caller set is kept:
      # CI keeps `~/.cache/zig`, the path its cache steps restore
      # (.github/workflows/ci.yml). A Zig that runs in the shell uses this
      # cache, so leave the shell before you build another Zig project.
      # The shells with Zig run this: `default`, and `browser`, `coverage`,
      # `workers` and `compare` through `inputsFrom`; direnv's `use flake` runs
      # `default`'s. `ownership` puts Zorg, a fork of Zig, on PATH and no
      # Zig. Zorg reads ZORG_GLOBAL_CACHE_DIR, not this variable, and its
      # own default is `~/.cache/zorg`. Its version string carries `+zorg`,
      # so its entries and Zig 0.17.0's never share a slot, even in one
      # directory (#197).
      zigGlobalCache = ''
        export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/zig-beni}"
      '';
      # The run-hash cache (tests/blackbox/run_hash.zig): one empty file
      # per emitted program that ran under Node and matched its golden, so
      # the tests skip Node for it next time. One directory serves every
      # worktree, because a digest covers every input of its verdict.
      # `build.zig` computes the same default when the variable is unset,
      # so this export is what a shell shows and what a tool reads. A
      # BENI_RUN_HASH_DIR that the caller set is kept: CI pins
      # `~/.cache/beni-run-hashes`, the path its cache steps restore and
      # save (.github/workflows/ci.yml). Empty means no cache. The shells
      # that run the tests export it: `default` and the shells that build
      # on it, and `ownership`, whose Zorg runs the same gates.
      runHashCache = ''
        export BENI_RUN_HASH_DIR="''${BENI_RUN_HASH_DIR-''${XDG_CACHE_HOME:-$HOME/.cache}/beni-run-hashes}"
      '';
    in
    {
      # `nix build .#checks.<system>.browser-chromium`: the `chromium` that
      # `devShells.<system>.browser` puts on PATH starts with an
      # LD_LIBRARY_PATH that names a libasound.so.2 the dynamic linker
      # cannot load. nixpkgs' own Chromium stops there ("…/libasound.so.2:
      # file too short", exit 127).
      checks = forAllSystems (system: pkgs: pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        browser-chromium = pkgs.runCommand "browser-chromium" {
          nativeBuildInputs = self.devShells.${system}.browser.nativeBuildInputs;
        } ''
          mkdir host
          : > host/libasound.so.2
          LD_LIBRARY_PATH=$PWD/host chromium --version > $out
        '';
      });

      devShells = forAllSystems (system: pkgs: rec {
        default = pkgs.mkShell {
          packages = [
            # Zig 0.17.0. The bundled 0.16 langref is stale for API signatures;
            # use this toolchain's std (`zig env` → lib_dir). ZLS remains out of
            # the shell until its stable release supports Zig 0.17.
            zig-overlay.packages.${system}."0.17.0"

            # Boundary 2 of the write-tests skill: emitted JavaScript is executed
            # and its behaviour asserted. Without a JS runtime those tests cannot
            # run at all, so it belongs in the dev shell, not on the host.
            pkgs.nodejs_24

            # .claude/skills/roc-zulip/scripts/*.fish parse API responses with jq.
            pkgs.jq
          ];

          # `zigGlobalCache` says which Zig cache is shared and which is not;
          # `runHashCache` where the verified run hashes live.
          shellHook = zigGlobalCache + runHashCache + ''
            echo "beni: zig $(zig version) · node $(node --version)"
          '';
        };

        # `nix develop .#coverage`: the default shell plus lcov, whose
        # `genhtml` turns the `lcov.info` that `zig build coverage` writes
        # into browsable pages. `zig build coverage` itself needs nothing
        # beyond the default shell; this is only for reading its report.
        coverage = pkgs.mkShell {
          inputsFrom = [ default ];
          packages = [ pkgs.lcov ];
        };

        # The ownership oracle is separate from the compiler gates. Its Lean
        # version is pinned by nixpkgs and proofs/ownership/lean-toolchain.
        ownership =
          let
            # The differential bridge builds beni through Zorg. Keep the
            # ownership shell independent of the caller's installed tools.
            zorgReleases = {
              x86_64-linux = { target = "x86_64-linux"; sha256 = "43bc8ba478639b840dddd83268a1b6491cf272dffce4006a7614824c5ac1e5f9"; };
              aarch64-linux = { target = "aarch64-linux"; sha256 = "2691c737b95b81bcee719ed6b3fa8ec828336837401e7879ab4060d4689716de"; };
              aarch64-darwin = { target = "aarch64-macos"; sha256 = "fe2fc1d21322795d8e9633ec51540da2b5d78d39ba0a10a63e25f8ce173c2384"; };
            };
            zorg = let release = zorgReleases.${system}; in pkgs.stdenvNoCC.mkDerivation {
              pname = "zorg";
              version = "0.17.1+zorg.1";
              src = pkgs.fetchurl {
                url = "https://github.com/canassa/zorg/releases/download/v0.17.1-zorg.1/zorg-${release.target}-0.17.1-zorg.1.tar.xz";
                inherit (release) sha256;
              };
              dontConfigure = true;
              dontBuild = true;
              dontFixup = true;
              installPhase = ''
                install -Dm755 zorg $out/bin/zorg
                mkdir -p $out/lib/zorg
                cp -r lib/. $out/lib/zorg/
              '';
            };
            leanVersion = builtins.replaceStrings [ "leanprover/lean4:v" "\n" ] [ "" "" ]
              (builtins.readFile ./proofs/ownership/lean-toolchain);
          in
          assert pkgs.lib.assertMsg (pkgs.lean4.version == leanVersion)
            "ownership: nixpkgs Lean and proofs/ownership/lean-toolchain must agree";
          pkgs.mkShell {
            packages = [ pkgs.lean4 pkgs.nodejs_24 ]
              # There is no upstream Zorg release for Intel macOS; the Lean
              # tools still work there, and the bridge needs Zorg on PATH.
              ++ pkgs.lib.optional (builtins.hasAttr system zorgReleases) zorg
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.util-linux ];
            # `zorg build gates` runs the same tests, on the same cache.
            shellHook = runHashCache;
          };

        # `nix develop .#browser`: the default shell plus Chromium, for
        # `zig build test-browser`, which runs the `browser/` corpus in a
        # headless browser instead of the happy-dom the gates use
        # (tests/blackbox/browser.zig). nixpkgs builds Chromium for Linux
        # only; elsewhere, point `-Dchrome=` at an installed Chrome. The
        # Chromium is `browserChromium`, which ignores the caller's
        # LD_LIBRARY_PATH.
        browser = pkgs.mkShell {
          inputsFrom = [ default ];
          packages = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ (browserChromium pkgs) ];
        };

        # `nix develop .#workers`: the default shell plus Cloudflare's
        # `wrangler`, for the `cloudflare` platform and its tests
        # (docs/design/boundary.md §9.12 (k)). A Worker runs in `workerd`,
        # which nixpkgs carries inside `wrangler` with Miniflare
        # (`lib/packages/miniflare`). The `cloudflare` platform PR adds the
        # tests' driver, `tests/workers/driver.mjs`, which imports Miniflare
        # from the file `BENI_MINIFLARE` names, starts `workerd` on
        # 127.0.0.1 and disposes it at the end, and the step `zig build
        # test-workers`, which runs the `workers/` corpus in this shell. No
        # CI job runs it yet (#697). Nothing is deployed and no account is
        # used. The closure is 2.2 GiB, of which 1.9 GiB is beside
        # `default`'s (Node, glibc and icu are shared), so the shell is its
        # own, as `browser` is: the Nix store CI saves is bounded at 2 GiB
        # (.github/workflows/ci.yml), and the gates run without it.
        # `wrangler dev` serves a built Worker from this shell. Two calls
        # that would leave the machine are off in the hook: Miniflare
        # fetches `workers.cloudflare.com/cf.json` when a caller leaves `cf`
        # unset (the driver passes `cf: false`), and every `wrangler`
        # command sends usage metrics unless told not to. Pinned by nixpkgs:
        # wrangler 4.93.0, Miniflare 4.20260518.0, workerd 1.20260518.1,
        # the versions §9.12 measured against.
        workers = pkgs.mkShell {
          inputsFrom = [ default ];
          packages = [ pkgs.wrangler ];
          shellHook = ''
            export BENI_MINIFLARE="${pkgs.wrangler}/lib/packages/miniflare/dist/src/index.js"
            export CLOUDFLARE_CF_FETCH_ENABLED=false
            export WRANGLER_SEND_METRICS=false
          '';
        };

        # `nix develop .#compare`: the default shell plus every compiler the
        # cross-language benchmark times (docs/design/compare-bench.md §8).
        compare =
          let
            cmp = nixpkgs-compare.legacyPackages.${pkgs.stdenv.hostPlatform.system};
          in
          pkgs.mkShell {
            inputsFrom = [ default ];
            packages = [
              cmp.elmPackages.elm
              cmp.gleam
              cmp.purescript
              cmp.spago
              cmp.typescript
              cmp.util-linux
            ];
          };
      });
    };
}
