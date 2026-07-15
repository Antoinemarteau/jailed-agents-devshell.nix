---
name: feedback_nix_idiomatic
description: Write idiomatic Nix — avoid hardcoded /bin/x store paths in scripts; prefer putting packages on PATH
metadata: 
  node_type: memory
  type: feedback
---

Write idiomatic Nix. Concretely: do not hardcode `${pkg}/bin/foo` store paths inside
devShell/wrapper scripts. Prefer adding the package to the shell's `packages` (or the
wrapper's env) so bare `foo` resolves from `PATH`; use `lib.getExe`/`getExe'` only when an
explicit path is genuinely needed.

**Why:** The user finds inline `bin/tmux`-style store paths unidiomatic and harder to read;
putting the tool on `PATH` is cleaner and doubles as making it available interactively.

**How to apply:** When wiring a package into a Nix devShell, reach for `packages = [ pkg ];`
+ bare invocation first. Reuse an existing package binding as the single source of truth
(e.g. `devshellHomeManager.config.programs.tmux.package`) rather than a fresh `pkgs.x`.

Related: [[feedback_nix_no_symlinks]], [[feedback_prose_minimal]]
