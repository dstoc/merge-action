#!/usr/bin/env bash
set -euo pipefail

: "${REBASE_GH_TOKEN:?REBASE_GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

repo=$GITHUB_REPOSITORY
base=${BASE_BRANCH:-main}
check_timeout=${CHECK_TIMEOUT:-30m}

as_rebaser() { GH_TOKEN="$REBASE_GH_TOKEN" gh "$@"; }

dismiss_approvals() {
    local pr=$1
    local reviews

    if ! reviews=$(as_rebaser api --paginate --slurp \
        "repos/$repo/pulls/$pr/reviews?per_page=100"); then
        echo "Failed to list reviews for #$pr"
        return 1
    fi

    mapfile -t review_ids < <(jq -r '
        add
        | sort_by(.submitted_at)
        | group_by(.user.login)
        | map(last)
        | .[]
        | select(.state == "APPROVED")
        | .id' <<<"$reviews")

    for review_id in "${review_ids[@]}"; do
        if ! as_rebaser api -X PUT \
            "repos/$repo/pulls/$pr/reviews/$review_id/dismissals" \
            -f message="Rebase conflict detected; approval must be renewed after conflict resolution." \
            >/dev/null; then
            echo "Failed to dismiss approval $review_id for #$pr"
            return 1
        fi
    done
}

prs=$(as_rebaser pr list -R "$repo" --base "$base" --state open --limit 1000 \
    --json number,createdAt,isDraft,reviewDecision)

mapfile -t numbers < <(jq -r '
    [.[] | select(.reviewDecision == "APPROVED" and (.isDraft | not))]
    | sort_by(.createdAt) | .[].number' <<<"$prs")

failed=0
for pr in "${numbers[@]}"; do
    echo "Processing $repo#$pr"

    if ! info=$(as_rebaser pr view "$pr" -R "$repo" \
        --json id,state,isDraft,reviewDecision,baseRefOid,headRefOid,mergeable); then
        failed=1
        continue
    fi

    if ! jq -e '
        .state == "OPEN" and (.isDraft | not) and
        .reviewDecision == "APPROVED"' <<<"$info" >/dev/null; then
        echo "Skipping #$pr: awaiting required approval"
        continue
    fi

    sha=$(jq -r .headRefOid <<<"$info")
    id=$(jq -r .id <<<"$info")
    base_sha=$(jq -r .baseRefOid <<<"$info")
    if ! behind=$(as_rebaser api "repos/$repo/compare/$base_sha...$sha" --jq .behind_by); then
        failed=1
        continue
    fi

    if (( behind > 0 )); then
        if [[ $(jq -r .mergeable <<<"$info") == "CONFLICTING" ]]; then
            echo "Rebase conflict detected for #$pr; dismissing approval"
            if ! dismiss_approvals "$pr"; then
                failed=1
            fi
            continue
        fi

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
            if [[ $(as_rebaser pr view "$pr" -R "$repo" --json mergeable --jq .mergeable 2>/dev/null || true) == "CONFLICTING" ]]; then
                echo "Rebase conflict detected for #$pr; dismissing approval"
                if ! dismiss_approvals "$pr"; then
                    failed=1
                fi
            else
                echo "Rebase failed for #$pr"
                failed=1
            fi
            continue
        fi

        if [[ ! $next =~ ^[0-9a-fA-F]{40}$ || $next == "$sha" ]]; then
            echo "Rebase did not return a new head for #$pr"
            failed=1
            continue
        fi
        sha=$next

        # The API update can take a moment to appear in the PR view.
        current=""
        for attempt in {1..10}; do
            current=$(as_rebaser pr view "$pr" -R "$repo" \
                --json headRefOid --jq .headRefOid) || break
            [[ $current == "$sha" ]] && break
            sleep 1
        done
        if [[ $current != "$sha" ]]; then
            echo "Head changed during rebase of #$pr"
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
        echo "PR #$pr changed or requires renewed approval"
        continue
    fi

    # The ruleset must also require an up-to-date branch: --match-head-commit
    # protects the PR head, not a concurrent change to the base branch.
    if ! as_rebaser pr merge "$pr" -R "$repo" \
        --squash --match-head-commit "$sha"; then
        echo "Merge failed for #$pr"
        failed=1
        continue
    fi
    echo "Merged #$pr"
done

exit "$failed"
