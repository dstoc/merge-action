# merge-action

A serial, event-driven merge worker for personal GitHub repositories without native merge queues.

Once a PR has the required GitHub approval, the worker processes approved PRs oldest-first, rebases outdated branches with `REBASE_GH_TOKEN`, waits for required CI, and squash-merges with a head-SHA guard. GitHub's stale-review policy decides whether an approval remains valid after a successful rebase. If an outdated PR conflicts with the base branch, the worker dismisses its current approvals so conflict resolution requires a fresh review.

## Setup

1. Configure the [expected GitHub branch protections](#github-branch-protection) on the target branch, including **exactly one required approval**, stale approval dismissal, and required CI checks against an up-to-date base.
2. Add `REBASE_GH_TOKEN` as an Actions secret in **each calling repository**. It is a personal-account token with Contents and Pull requests **read/write** on the calling repository. The account must also be allowed to dismiss reviews if review dismissal is restricted.
3. After publishing the first release as `v1`, copy [examples/caller.yml](examples/caller.yml) to `.github/workflows/merge.yml` in each repository. It references `dstoc/merge-action/.github/workflows/merge.yml@v1`.
4. Any eligible reviewer can provide the initial approval. An approval event starts the worker. A push to `main` also triggers queue processing; use `workflow_dispatch` for manual recovery.

For public repositories, standard GitHub-hosted Actions runners are free. The calling workflows execute on trusted workflow definitions; the worker never checks out untrusted PR code and does not expose tokens to PR scripts.

## GitHub branch protection

Configure an active branch ruleset under **Settings → Rules → Rulesets**, targeting the base branch (typically `main`).

### Required settings

| Setting | Value |
| --- | --- |
| Require a pull request before merging | Enabled |
| Required approvals | **Exactly 1** |
| Dismiss stale pull request approvals when new commits are pushed | **Enabled** |
| Require status checks to pass | Enabled |
| Require branches to be up to date before merging | Enabled |
| Required status checks | Your build, test, and other independent CI checks |

GitHub records the reviewed diff and invalidates an approval when an update changes the reviewed state. The worker does not replace an approval that GitHub dismisses after rebasing; that PR waits for another human approval.

**Do not require the merge-worker workflow itself as a status check.** Only require the independent checks that validate the PR. The up-to-date requirement is essential: `--match-head-commit` protects against a changed PR head, not a concurrent update to `main`.

### Recommended settings

| Setting | Value | Reason |
| --- | --- | --- |
| Require approval of the most recent reviewable push | Disabled | Stale-review dismissal is the approval policy; requiring last-push approval can independently require another review after the worker rebases. |
| Require conversation resolution before merging | Enabled | Prevent merging with unresolved review discussions. |
| Block force pushes | Enabled | Protect the target branch. |
| Bypass permissions | None for the worker account | Ensure automated merges are subject to the same rules. |

If review dismissal is restricted, the account behind `REBASE_GH_TOKEN` must be included in the allowed users/apps. The same token performs branch updates, dismisses approvals on conflicts, reads CI state, and merges.

### Repository settings

Under **Settings → General → Pull Requests**, enable **Allow squash merging**. The worker explicitly uses `gh pr merge --squash`; other merge methods can be disabled if you want all merges to follow this policy.

GitHub's native merge queue and auto-merge features are not required. The worker serializes merging through the calling workflow's concurrency configuration.

## Behavior

- Any approval that satisfies the repository's required-review rules can authorize the worker; no particular initial reviewer is required. GitHub enforces reviewer eligibility.
- A rebase is only attempted when the PR is behind the target branch. It uses GitHub's GraphQL branch-update mutation with `expectedHeadOid` to reject concurrent head changes.
- After a successful rebase, the worker does **not** submit another approval. GitHub's stale-review rules determine whether the existing approval is still valid. If it is dismissed, the worker leaves the PR waiting for another human review.
- If an outdated PR has merge conflicts, the worker dismisses its current effective approvals with the reason `Rebase conflict detected; approval must be renewed after conflict resolution.` It also checks again after a failed rebase in case GitHub only reports the conflict then.
- The merge uses `gh pr merge --squash --match-head-commit`. Repository rules enforce approvals, checks, and the up-to-date base.
- A PR that simply needs renewed approval is skipped without making the worker run fail. Operational failures such as API errors, CI failures/timeouts, or merge failures are reported and cause a nonzero worker exit after the remaining queue entries are attempted.
- Trigger concurrency must be defined in each caller; GitHub concurrency groups are scoped to each repository.

## Calling the reusable workflow

See [examples/caller.yml](examples/caller.yml). Once released:

```yaml
jobs:
  merge:
    uses: dstoc/merge-action/.github/workflows/merge.yml@v1
    secrets:
      REBASE_GH_TOKEN: ${{ secrets.REBASE_GH_TOKEN }}
```

You can also use the standalone composite action in a normal job with
`uses: dstoc/merge-action/.github/actions/merge@v1`; pass the `rebase-token` input. The reusable workflow references the action at its **exact running commit** via GitHub's `$/` syntax, so the two versions cannot drift.

## Limitations

- Review dismissal requires the `REBASE_GH_TOKEN` account to have permission to dismiss reviews. If a ruleset restricts dismissal, explicitly allow that account.
- A clean rebase is not proof of semantic equivalence. The worker deliberately delegates approval invalidation to GitHub's stale-review policy rather than comparing pre/post-rebase patches itself.
- The worker is a serial queue, not a speculative merge train. It uses GitHub's actual required checks and ruleset as the final merge gate.
- The script expects `gh`, `jq`, `timeout`, and Bash (available on `ubuntu-latest`). It uses GitHub.com GraphQL rebase support and the self-repository `$/` syntax (not GitHub Enterprise Server).
- No cron schedule is configured. Approval and `main` push events trigger runs; `workflow_dispatch` enables manual retries.
