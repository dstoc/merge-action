# merge-action

A small event-driven helper for repositories that use GitHub's native auto-merge but want approved pull requests advanced serially.

The action does **not merge pull requests**. GitHub owns the merge, required checks, review enforcement, and final branch-protection decision. The worker only finds the oldest approved PR with auto-merge enabled, rebases it onto the current base branch when necessary, then exits.

## Setup

1. Enable **Allow auto-merge** under **Settings → General → Pull Requests**. Enable the merge method you want auto-merge to use (for example, squash merging).
2. Configure the target branch ruleset as described below, including required reviews, required CI, stale-review dismissal, and **Require branches to be up to date before merging**.
3. Create a fine-grained PAT named `PR_GH_TOKEN` with repository permission **Pull requests: Read and write**. `Contents: write` is not required. The token owner must have repository write access so updating a PR branch does not disable auto-merge.
4. Add `PR_GH_TOKEN` as an Actions secret in each calling repository.
5. Copy [examples/caller.yml](examples/caller.yml) to `.github/workflows/merge.yml` in each repository.

For public repositories, standard GitHub-hosted Actions runners are free. The worker never checks out PR code and never exposes the PAT to PR scripts.

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

GitHub decides whether a review remains valid after a rebase. If the rebase invalidates approval, the PR simply waits for another human review while auto-merge remains configured.

**Do not require this workflow itself as a status check.** Only require the independent checks that validate the PR.

### Recommended settings

| Setting | Value | Reason |
| --- | --- | --- |
| Require approval of the most recent reviewable push | Disabled | Stale-review dismissal already defines the review policy. |
| Require conversation resolution before merging | Enabled | Prevent merging with unresolved review discussions. |
| Block force pushes | Enabled | Protect the target branch. |
| Bypass permissions | None for the worker account | Keep branch updates subject to normal repository rules. |

## Behavior

A PR is considered for the queue when it is open, non-draft, approved, and has auto-merge enabled.

The worker processes candidates oldest-first:

- Conflicting PRs are skipped. Resolving the conflict pushes a new head commit, which lets GitHub's stale-review policy decide whether another approval is required.
- If GitHub has not finished computing mergeability, the worker exits and waits for a later event rather than advancing a younger PR.
- If the oldest eligible PR is already up to date, the worker exits. GitHub auto-merge waits for the remaining checks and merges it when all repository rules are satisfied.
- If the oldest eligible PR is behind the base branch, the worker runs `gh pr update-branch --rebase` once and exits. CI and review policy then run normally on the updated head.
- When GitHub auto-merges a PR, the resulting push to the base branch triggers another run, advancing the next PR.

This intentionally makes GitHub the final merge gate. There is no CI polling, merge command, merge timeout, synthetic approval, or Contents-write credential in the worker.

## Calling the reusable workflow

See [examples/caller.yml](examples/caller.yml). Once released:

```yaml
jobs:
  advance:
    uses: dstoc/merge-action/.github/workflows/merge.yml@v1
    secrets:
      PR_GH_TOKEN: ${{ secrets.PR_GH_TOKEN }}
```

You can also use the standalone composite action in a normal job with `uses: dstoc/merge-action/.github/actions/merge@v1`; pass the `pr-token` input.

The example caller reacts to:

- an approval being submitted;
- auto-merge being enabled;
- a PR head changing, including conflict resolution or a worker rebase;
- a push to `main`, including the previous auto-merge completing; and
- manual dispatch for recovery.

Caller concurrency serializes worker invocations within each repository.

## Permissions and security boundary

`PR_GH_TOKEN` needs only **Pull requests: Read and write**. In particular, it does not need **Contents: write**, so the worker credential cannot directly merge a PR or perform ordinary repository-content writes. Pull-request write permission is still powerful: it can mutate PR state/reviews and update PR branches, so scope the PAT to only the repositories that should participate.

The reusable workflow's `contents: read` permission applies only to the ephemeral `GITHUB_TOKEN` used by Actions; it is not granted to `PR_GH_TOKEN`.

## Limitations

- The queue assumes GitHub native auto-merge is enabled on each PR that should merge. The action never enables auto-merge itself.
- A head PR whose required checks fail remains the queue head until its state changes or it is no longer eligible. This is deliberate serial-queue behavior.
- Conflicting PRs do not block younger eligible PRs; they re-enter consideration after the conflict is resolved and any required review is restored.
- The worker expects `gh`, `jq`, and Bash, all available on `ubuntu-latest`.
- The rebase path uses `gh pr update-branch --rebase`; the PAT therefore needs permission to update PR branches but not general Contents write access.
