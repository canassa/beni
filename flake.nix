{
  description = "beni — an Elm-like language that compiles to JavaScript";

  # Pinned to the same channel as the host (/etc/nixos). Zig releases move the
  # std API, so the toolchain is upgraded DELIBERATELY: bump this input, read the
  # Zig release notes, fix what breaks, commit. Never track unstable here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # The compilers under test in bench/compare (docs/design/compare-bench.md
  # §8.1): a separate, unstable pin, so upgrading Elm, Gleam, Roc, PureScript
  # or TypeScript never moves the compiler's own toolchain. Bump it alone to
  # re-measure against newer compilers; the results file records the rev.
  inputs.nixpkgs-compare.url = "github:NixOS/nixpkgs/b1b875982b17dabde9b4a37f3e229e74913e6db3";

  outputs = { self, nixpkgs, nixpkgs-compare }:
    let
      # The shell is the same on every machine the compiler is developed on;
      # only the nixpkgs instance differs. Naming one system here was enough
      # until the first non-NixOS checkout, which then got no devShell at all.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: rec {
        default = pkgs.mkShell {
          packages = [
            # 0.16.0 — the version the bundled langref in
            # .claude/skills/zig-developer/zig-langref/ documents. Keep zls in
            # lockstep. NOTE: references/zig is the submodule at master, ~2100
            # commits ahead of this; it is read for compiler ARCHITECTURE, not for
            # API signatures. For an exact signature, trust this toolchain's own
            # std (`zig env` → lib_dir) or the langref.
            pkgs.zig
            pkgs.zls

            # Boundary 2 of the write-tests skill: emitted JavaScript is executed
            # and its behaviour asserted. Without a JS runtime those tests cannot
            # run at all, so it belongs in the dev shell, not on the host.
            pkgs.nodejs_24

            # .claude/skills/roc-zulip/scripts/*.fish parse API responses with jq.
            pkgs.jq
          ];

          # Each worktree keeps its own `.zig-cache`. Sharing one cache
          # across worktrees is unsafe with Zig 0.16: its manifests record
          # build-root-relative paths, so a worktree could be handed a binary
          # built from another worktree's sources.
          shellHook = ''
            echo "beni: zig $(zig version) · node $(node --version) · zls $(zls --version)"
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

        # `nix develop .#browser`: the default shell plus Chromium, for
        # `zig build test-browser`, which runs the `browser/` corpus in a
        # headless browser instead of the happy-dom the gates use
        # (tests/blackbox/browser.zig). nixpkgs builds Chromium for Linux
        # only; elsewhere, point `-Dchrome=` at an installed Chrome.
        browser = pkgs.mkShell {
          inputsFrom = [ default ];
          packages = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.chromium ];
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
