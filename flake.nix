{
  description = "beni — an Elm-like language that compiles to JavaScript";

  # Pinned to the same channel as the host (/etc/nixos). Zig releases move the
  # std API, so the toolchain is upgraded DELIBERATELY: bump this input, read the
  # Zig release notes, fix what breaks, commit. Never track unstable here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      # The shell is the same on every machine the compiler is developed on;
      # only the nixpkgs instance differs. Naming one system here was enough
      # until the first non-NixOS checkout, which then got no devShell at all.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
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

          shellHook = ''
            echo "beni: zig $(zig version) · node $(node --version) · zls $(zls --version)"
          '';
        };
      });
    };
}
