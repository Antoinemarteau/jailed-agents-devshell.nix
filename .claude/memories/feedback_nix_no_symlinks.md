---
name: feedback-nix-no-symlinks
description: Never create symlinks explicitly in nix derivations; use wrapper scripts or makeWrapper instead
metadata: 
  node_type: memory
  type: feedback
---

Never create symlinks explicitly in nix derivations (e.g. no `ln -s` in `postBuild` or `postInstall`).

**Why:** The user flagged this as a nix anti-pattern. Nix has proper tooling for this (`pkgs.makeWrapper`, `pkgs.writeShellScriptBin`, `pkgs.symlinkJoin` for joining store paths — but the manual `ln -s` inside a derivation build is wrong).

**How to apply:** When needing a binary alias or wrapper, use `pkgs.writeShellScriptBin "name" ''exec real-binary "$@"''` or `pkgs.makeWrapper`. Never use `ln -s` in derivation build phases.
