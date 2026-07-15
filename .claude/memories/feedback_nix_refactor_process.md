---
name: feedback-nix-refactor-process
description: "How this user wants incremental Nix refactors done: tiny steps, drvPath-equivalence checks, terse behavior-only comments"
metadata: 
  node_type: memory
  type: feedback
---

This user drives large Nix refactors (e.g. splitting `jailed-agents.nix`/`flake.nix` into
generic-vs-program-specific, see [[project_jailed_agents_devshell]]) as a long sequence of
small, explicit, one-thing-at-a-time requests — "move X to file Y", "rename param A to B",
"is it possible to move Z into W" — rather than handing over a big spec up front.

**Why:** keeps every step individually reviewable and revertible, and lets each step be
verified in isolation (`nix flake check` / drvPath equivalence) before the next lands.

**How to apply:**
- Do exactly the requested step, nothing more. Don't bundle in adjacent cleanups the user
  didn't ask for, even if they seem like an obvious follow-on — the user will ask for them
  next if wanted (and often does, immediately after).
- After a structural move/rename, verify with `nix flake check --no-build` (or
  `nix eval --raw .#devShells.<system>.default.drvPath`) and compare the drvPath to before
  the change when the step is claimed to be behavior-preserving — identical drvPath is the
  proof, not just "it evaluates." `git add -A -- <files>` first since flakes only see
  git-tracked files.
- **Comments must describe current behavior only, tersely (a line or two, occasionally up
  to ~4) — never the design rationale, alternatives considered, or history that led to the
  current shape.** When asked to shrink a comment, cut the "why we chose this over X"
  narrative first; keep only what a reader needs to use the code correctly right now. Seen
  repeatedly: user rejected/asked to shrink comments that explained *how we got here* even
  when technically accurate — restate what's true today, not the journey. Related:
  [[feedback_prose_minimal]], [[feedback_preserve_comments]] (still don't delete comments
  wholesale unless asked — shrink or edit them).
- When a change nets out to "no behavior change, just moved/renamed", say so plainly and
  cite the matching drvPath; don't over-explain.
