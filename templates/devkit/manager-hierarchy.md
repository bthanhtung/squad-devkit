<!-- squad-devkit template: squad-devkit refreshes this file while this line is present; delete the line to keep your own edits. -->
### Sub-managers (hierarchy mode)
- Use sub-managers only when complexity is high AND the task splits into ≥ 2 independent areas; otherwise brief workers directly (sub-managers add 2-3 AI turns each, so they cost more on small tasks).
- One sub-manager per area: `squad-worker sm-<area> --role sub-manager --engine agy --model gemini-4-argon-high --own <area paths> --budget-tokens <n> --max-children <1-3> --plan ... --brief-file -`. The brief states the area goal, owned paths and acceptance; the sub-manager plans children, the system runs them in its worktree, and it reports once.
- Depth is limited to 2: sub-managers cannot start sub-managers. Children run with `--parent`.
- You alone merge (`squad-worker --merge sm-<area>`), commit and push; review the sub-manager's diff like any worker's.
- `squad-worker --tree` shows the hierarchy and branch token totals.

