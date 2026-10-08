#!/usr/bin/env bash
set -euo pipefail

: "${PR_GH_TOKEN:?PR_GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

repo=$GITHUB_REPOSITORY
base=${BASE_BRANCH:-main}

as_pr() { GH_TOKEN="$PR_GH_TOKEN" gh "$@"; }

prs=$(as_pr pr list -R "$repo" --base "$base" --state open --limit 1000 \
    --json number,createdAt,isDraft,reviewDecision,autoMergeRequest)

mapfile -t numbers < <(jq -r '
    [.[] | select(
        .reviewDecision == "APPROVED" and
        (.isDraft | not) and
        .autoMergeRequest != null
    )]
    | sort_by(.createdAt)
    | .[].number' <<<"$prs")

for pr in "${numbers[@]}"; do
    if ! info=$(as_pr pr view "$pr" -R "$repo" \
        --json state,isDraft,reviewDecision,autoMergeRequest,mergeable,mergeStateStatus); then
        exit 1
    fi

    if ! jq -e '
        .state == "OPEN" and
        (.isDraft | not) and
        .reviewDecision == "APPROVED" and
        .autoMergeRequest != null
        ' <<<"$info" >/dev/null; then
        continue
    fi

    mergeable=$(jq -r .mergeable <<<"$info")
    merge_state=$(jq -r .mergeStateStatus <<<"$info")

    if [[ $mergeable == "CONFLICTING" ]]; then
        echo "Skipping #$pr: conflicts with $base"
        continue
    fi

    if [[ $mergeable == "UNKNOWN" || $merge_state == "UNKNOWN" ]]; then
        echo "Waiting for GitHub to determine mergeability of #$pr"
        exit 0
    fi

    if [[ $merge_state != "BEHIND" ]]; then
        echo "Queue head #$pr is up to date; GitHub auto-merge owns the remaining gates ($merge_state)"
        exit 0
    fi

    echo "Rebasing queue head #$pr onto $base"
    as_pr pr update-branch "$pr" -R "$repo" --rebase
    echo "Updated #$pr; GitHub auto-merge owns the remaining gates"
    exit 0
done

echo "No approved auto-merge PR is ready to advance"
