#!/usr/bin/env bash
set -euo pipefail

: "${REBASE_GH_TOKEN:?REBASE_GH_TOKEN must be set}"
: "${APPROVE_GH_TOKEN:?APPROVE_GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

repo=$GITHUB_REPOSITORY
base=${BASE_BRANCH:-main}
check_timeout=${CHECK_TIMEOUT:-30m}

as_rebaser() { GH_TOKEN="$REBASE_GH_TOKEN" gh "$@"; }
as_approver() { GH_TOKEN="$APPROVE_GH_TOKEN" gh "$@"; }

bot=$(as_approver api user --jq .login)
prs=$(as_rebaser pr list -R "$repo" --base "$base" --state open --limit 1000 \
    --json number,createdAt,isDraft,reviewDecision)

mapfile -t numbers < <(jq -r '
    [.[] | select(.reviewDecision == "APPROVED" and (.isDraft | not))]
    | sort_by(.createdAt) | .[].number' <<<"$prs")

failed=0
for pr in "${numbers[@]}"; do
    echo "Processing $repo#$pr"

    if ! info=$(as_rebaser pr view "$pr" -R "$repo" \
        --json id,state,isDraft,reviewDecision,latestReviews,baseRefOid,headRefOid); then
        failed=1
        continue
    fi

    # Only the external review bot's approval authorizes the initial merge.
    if ! jq -e --arg bot "$bot" '
        .state == "OPEN" and (.isDraft | not) and
        .reviewDecision == "APPROVED" and
        any(.latestReviews[]?;
            (.author.login // "" | ascii_downcase) == ($bot | ascii_downcase)
            and .state == "APPROVED")' <<<"$info" >/dev/null; then
        echo "Skipping #$pr: awaiting the review bot's approval"
        continue
    fi

    sha=$(jq -r .headRefOid <<<"$info")
    id=$(jq -r .id <<<"$info")
    base_sha=$(jq -r .baseRefOid <<<"$info")
    if ! behind=$(as_rebaser api "repos/$repo/compare/$base_sha...$sha" --jq .behind_by); then
        failed=1
        continue
    fi

    rebased=false
    if (( behind > 0 )); then
        echo "Rebasing #$pr onto $base"
        if ! next=$(as_rebaser api graphql \
            -f query='mutation($id: ID!, $sha: GitObjectID!) {
                updatePullRequestBranch(input: {
                    pullRequestId: $id,
                    expectedHeadOid: $sha,
                    updateMethod: REBASE
                }) {
                    pullRequest { headRefOid }
                }
            }' -f id="$id" -f sha="$sha" \
            --jq '.data.updatePullRequestBranch.pullRequest.headRefOid'); then
            echo "Rebase failed for #$pr"
            failed=1
            continue
        fi

        if [[ ! $next =~ ^[0-9a-fA-F]{40}$ || $next == "$sha" ]]; then
            echo "Rebase did not return a new head for #$pr; not approving"
            failed=1
            continue
        fi
        sha=$next
        rebased=true

        # The API update can take a moment to appear in the PR view.
        current=""
        for attempt in {1..10}; do
            current=$(as_rebaser pr view "$pr" -R "$repo" \
                --json headRefOid --jq .headRefOid) || break
            [[ $current == "$sha" ]] && break
            sleep 1
        done
        if [[ $current != "$sha" ]]; then
            echo "Head changed during rebase of #$pr; not approving"
            failed=1
            continue
        fi
    fi

    # Reapprove the exact rebased commit before waiting for CI. If CI fails,
    # the review persists, allowing the next worker run to retry the checks.
    if [[ $rebased == true ]]; then
        if ! as_approver api -X POST "repos/$repo/pulls/$pr/reviews" \
            -f event=APPROVE -f commit_id="$sha" \
            -f body="Previously reviewed PR rebased; required CI must pass before merge." >/dev/null; then
            echo "Bot reapproval failed for #$pr"
            failed=1
            continue
        fi
    fi

    echo "Waiting for required CI on #$pr ($sha)"
    if ! GH_TOKEN="$REBASE_GH_TOKEN" timeout "$check_timeout" \
        gh pr checks "$pr" -R "$repo" --required --watch --fail-fast; then
        echo "Required CI failed, is absent, or timed out for #$pr"
        failed=1
        continue
    fi

    if ! current=$(as_rebaser pr view "$pr" -R "$repo" \
        --json headRefOid,state,isDraft,reviewDecision); then
        failed=1
        continue
    fi
    if ! jq -e --arg sha "$sha" '
        .headRefOid == $sha and .state == "OPEN" and (.isDraft | not)
        and .reviewDecision == "APPROVED"
        ' <<<"$current" >/dev/null; then
        echo "PR #$pr changed or review was blocked during CI"
        failed=1
        continue
    fi

    # The ruleset must also require an up-to-date branch: --match-head-commit
    # protects the PR head, not a concurrent change to the base branch.
    if ! as_approver pr merge "$pr" -R "$repo" \
        --squash --match-head-commit "$sha"; then
        echo "Merge failed for #$pr"
        failed=1
        continue
    fi
    echo "Merged #$pr"
done

exit "$failed"
