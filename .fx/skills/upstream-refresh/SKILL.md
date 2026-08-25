# Upstream refresh

Use this skill when updating every attached OMIFX worktree from `upstream/main`.

## Contract

Run the deterministic planner from the repository root:

```bash
python3 scripts/upstream_refresh.py plan
```

The command fetches `upstream/main` once, pins its commit, discovers attached
worktrees, and writes an immutable plan under the common Git directory.

Review the JSON plan before applying it. Dirty worktrees, detached worktrees,
and worktrees with an existing merge, cherry-pick, revert, or rebase are never
mutated. Apply a plan only after those entries are intentionally handled:

```bash
python3 scripts/upstream_refresh.py apply --plan /path/from-plan.json
```

The apply operation rebases each clean OMIFX branch onto the same pinned
upstream commit and creates a backup ref before changing it. It processes
branches independently and stops on the first conflict without guessing. The
agent resolves that conflict in the reported worktree, then runs the normal
`git rebase --continue` there. Never use `git reset --hard`, blanket
`checkout --ours`, or blanket `checkout --theirs` during resolution.

## Invariants

- The source commit is fetched and recorded once per plan.
- Each branch keeps its own commits; only its old shared base is replaced.
- A dirty or already-active worktree is skipped, never stashed or reset.
- Every mutation has a backup under `refs/backup/omifx-upstream-refresh/`.
- Re-running a plan is safe: completed or skipped entries are not replayed.
- Conflicts are semantic work for the agent, not automatic policy decisions.

After resolution, verify the affected branch with its focused tests and build,
then exercise `./zig-out/bin/fx` as required by the repository instructions.
