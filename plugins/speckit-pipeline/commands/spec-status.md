---
description: Show the current feature's pipeline state — which phases ran, on which model, and what they cost
allowed-tools: Bash, Read
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/spec-status"
```

Report what it prints: the per-phase table, the total, and what the next action
is. Add anything useful from the artifacts themselves if the user asks — but the
table above is the authority on what ran, and this command must not re-derive it
from which files happen to exist.

That distinction is the whole reason the state file exists. A present `plan.md`
cannot tell you whether planning finished or was killed halfway through writing
it, so if `spec-status` reports no recorded state, say exactly that rather than
inferring progress from a directory listing.

Exit `1` means there is no state to show — either no feature is current, or none
has been run through the pipeline yet.
