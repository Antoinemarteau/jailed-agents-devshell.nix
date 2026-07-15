---
name: feedback-preserve-comments
description: Do not remove existing comments from source files when editing
metadata: 
  node_type: memory
  type: feedback
---

Preserve all existing comments in files when making edits. Do not remove comments, even if they seem redundant or could be cleaned up.

**Why:** User explicitly asked to keep comments after I removed several from flake.nix during an edit.

**How to apply:** When editing any file, carry over all existing comments into the new version. The only exception is if the user explicitly asks to remove a specific comment.
