---
name: feedback-prose-minimal
description: "Prefer minimal, in-place additions to prose (README, comments) over new sections or verbose expansions"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f8f258f2-8e1d-427f-bbb8-eeb476ec4cf0
---

For docs and code comments in this project, prefer *minimal in-place additions*
over introducing new sections or headings. When a single sentence into an
existing paragraph conveys the fact, do that instead of a dedicated section.

**Why:** the user has trimmed my comments multiple times (once tightening the
`withClaudeConfigInit` comment in `jailed-agents/flake.nix`, once rejecting a
new "Supported platforms" section in the README in favor of one added sentence
in the existing "Technical details" section). Verbose additions get pruned;
concise ones stick.

**How to apply:**
- Before drafting a new section, ask whether the info fits into an existing one
- Match density: sparse READMEs stay sparse; a single technical detail is a
  single sentence, not a two-paragraph explanation with headers
- The rule from [[.claude/rules/code-comments]] applies to prose docs too:
  no motivating stories, no historical context, no "for completeness"
  digressions — state what is true, briefly
- When an Edit is rejected with "do not add the comment", omit the comment
  entirely rather than trying a shorter version — the code should stand alone
- README links (2026-07-15): put a project's hyperlink at its FIRST mention in the
  intro, never repeated in usage steps; usage steps stay plain and terse (e.g. just
  "Claude launches julia-mcp on demand", no parenthetical detail chains)
