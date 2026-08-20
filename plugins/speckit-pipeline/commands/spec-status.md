---
description: Show the current feature's pipeline state — which phases ran, on which model, and what they cost
allowed-tools: Bash, Read
---

Report the state of the current spec-kit feature.

1. Resolve the feature directory:
   ```bash
   jq -r '.feature_directory' .specify/feature.json 2>/dev/null \
     || ./.specify/scripts/bash/check-prerequisites.sh --json | jq -r .FEATURE_DIR
   ```

2. Show which artifacts exist and which phases the pipeline has recorded:
   ```bash
   FD=<feature dir>
   ls -la "$FD"
   [ -f "$FD/.pipeline/state.json" ] && jq . "$FD/.pipeline/state.json"
   [ -f "$FD/.pipeline/cost.log" ] && column -t -s$'\t' "$FD/.pipeline/cost.log"
   ```

3. Report as a short table: phase, status, model, effort, cost, turns — plus the
   total. Then say what the next action is (`/spec-run --resume`, or which gate
   is waiting on the user).

If there is no `.pipeline/state.json`, say so plainly rather than inferring
progress from which files exist. A present `plan.md` does not distinguish
"planning finished" from "planning was killed halfway through writing it" — that
distinction is exactly what the state file records, and guessing it is how a
half-written plan becomes a task list.
