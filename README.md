# merge-action

A serial, event-driven merge worker for personal GitHub repositories without native merge queues.

Once a PR has the required GitHub approval, the worker processes approved PRs oldest-first, rebases outdated branches with `REBASE_GH_TOKEN`, immediately reapproves the rebased head with `APPROVE_GH_TOKEN`, waits for required CI, and squash-merges with a head-SHA guard. If CI, rebase, approval or merge fails, it skips the PR and continues with the remaining queue.

## Setup

1. Set repository rules on the target branch: **Require a pull request before merging**, at least one required approval, **Require approval of the most recent reviewable push**, **Require status checks to pass**, and **Require branches to be up to date before merging**. Select your required CI checks. The up-to-date requirement is essential: `--match-head-commit` only protects the PR head, not concurrent updates to `main`.
2. Add Actions secrets in **each calling repository**:
   - `REBASE_GH_TOKEN`: your personal-account token with Contents and Pull requests **read/write** on the calling repository.
   - `APPROVE_GH_TOKEN`: a separate approver's token with Contents and Pull requests **read/write** on the same repository. The account needs appropriate repository access and must be eligible to approve the rebased PR (it cannot be the PR author or the account that made the latest reviewable push).
3. Copy [examples/caller.yml](examples/caller.yml) to `.github/workflows/merge.yml` in each repository and replace `@main` with a released tag (such as `@v1`) or a pinned full commit SHA **after this repository's initial PR is merged and released**.
4. Any eligible reviewer can provide the initial approval. An approval event starts the worker. A push to `main` also triggers queue processing; use `workflow_dispatch` for manual recovery.

For public repositories, standard GitHub-hosted Actions runners are free. The calling workflows execute on trusted workflow definitions; the worker never checks out untrusted PR code and does not expose tokens to PR scripts.

## Behavior

- Any approval that satisfies the repository's required-review rules can authorize the worker; no particular initial reviewer is required. GitHub enforces reviewer eligibility and latest-push approval requirements.
- A rebase is only attempted when the PR is behind the target branch. It uses GitHub's GraphQL branch-update mutation with `expectedHeadOid` to reject concurrent head changes.
- After a successful rebase, the worker immediately submits a REST review with `commit_id` set to the rebased head, then waits for required CI. If CI fails or times out, the approval persists for the next run. Without a rebase, the existing approval remains in force.
- The merge uses `gh pr merge --squash --match-head-commit`. Repository rules enforce approvals, checks, and the up-to-date base.
- A failed PR is reported and skipped; the remaining PRs are attempted. A failing run returns a nonzero exit status. With no scheduled polling, retry a failed run manually or rely on the next approval or push to `main`.
- Trigger concurrency must be defined in each caller; GitHub concurrency groups are scoped to each repository.

## Calling the reusable workflow

See [examples/caller.yml](examples/caller.yml). Once released:

```yaml
jobs:
  merge:
    uses: dstoc/merge-action/.github/workflows/merge.yml@v1
    secrets:
      REBASE_GH_TOKEN: ${{ secrets.REBASE_GH_TOKEN }}
      APPROVE_GH_TOKEN: ${{ secrets.APPROVE_GH_TOKEN }}
```

You can also use the standalone composite action in a normal job with
`uses: dstoc/merge-action/.github/actions/merge@v1`; pass inputs `rebase-token` and `approve-token`. The reusable workflow references the action at its **exact running commit** via GitHub's `$/` syntax, so the two versions cannot drift.

## Limitations

- A clean rebase does not prove semantic equivalence. Auto-reapproval applies to PRs that already satisfy GitHub's required-review rules; the worker deliberately does not compare pre/post-rebase patches. GitHub rejects an ineligible approver or a merge that violates branch rules.
- The worker is a serial queue, not a speculative merge train. It uses GitHub's actual required checks and ruleset as the final merge gate.
- The script expects `gh`, `jq`, `timeout`, and Bash (available on `ubuntu-latest`). It uses GitHub.com GraphQL rebase support and the self-repository `$/` syntax (not GitHub Enterprise Server).
- No cron schedule is configured. Approval and `main` push events trigger runs; `workflow_dispatch` enables manual retries.
