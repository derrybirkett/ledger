#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
REVIEW_SECONDS=$((24 * 3600))
GRACE_SECONDS=$((48 * 3600))
NOW_EPOCH=$(date +%s)
TODAY=$(date -u '+%Y-%m-%d')

echo "=== Ledger Check — $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

gap_count=0
gap_text=""

add_gap() {
  local title="$1"
  local detail="$2"
  gap_count=$(( gap_count + 1 ))
  gap_text+="### ${title}"$'\n'"${detail}"$'\n\n'
}

# Rule 1: Delta ran when it should have skipped
check_delta_ran_when_should_skip() {
  local run_json
  run_json=$(gh run list --workflow=delta.yml --limit 1 \
    --json conclusion,createdAt \
    --jq '.[] | select(.conclusion == "success")' 2>/dev/null || echo "")
  [[ -z "$run_json" ]] && return 0

  local run_created_at
  run_created_at=$(echo "$run_json" | jq -r '.createdAt')
  local run_epoch; run_epoch=$(date -d "$run_created_at" +%s)
  local run_age; run_age=$(( NOW_EPOCH - run_epoch ))
  (( run_age >= REVIEW_SECONDS )) && return 0

  local pre_existing
  pre_existing=$(gh pr list --state open --json headRefName,createdAt \
    --jq "[.[] | select(.headRefName | startswith(\"delta/\")) | select(.createdAt < \"${run_created_at}\")] | length" \
    2>/dev/null || echo "0")

  local new_pr_nums
  new_pr_nums=$(gh pr list --state open --json number,headRefName,createdAt \
    --jq "[.[] | select(.headRefName | startswith(\"delta/\")) | select(.createdAt >= \"${run_created_at}\")] | map(\"#\" + (.number | tostring)) | join(\", \")" \
    2>/dev/null || echo "")

  if (( pre_existing > 0 )) && [[ -n "$new_pr_nums" ]]; then
    add_gap "Delta ran when it should have skipped" \
      "${pre_existing} open delta PR(s) existed before the run at ${run_created_at}. Delta opened new PR(s): ${new_pr_nums}."
  fi
}

# Rule 2: Delta failed when it should have run
check_delta_failed_when_should_run() {
  local run_json
  run_json=$(gh run list --workflow=delta.yml --limit 5 \
    --json conclusion,createdAt \
    --jq '[.[] | select(.conclusion == "failure" or .conclusion == "success")] | first' 2>/dev/null || echo "")
  [[ -z "$run_json" ]] && return 0

  local run_created_at
  run_created_at=$(echo "$run_json" | jq -r '.createdAt')
  local run_epoch; run_epoch=$(date -d "$run_created_at" +%s)
  local run_age; run_age=$(( NOW_EPOCH - run_epoch ))
  local run_conclusion
  run_conclusion=$(echo "$run_json" | jq -r '.conclusion')

  (( run_age >= REVIEW_SECONDS )) && return 0
  [[ "$run_conclusion" != "failure" ]] && return 0

  local open_delta_prs
  open_delta_prs=$(gh pr list --state open --json headRefName \
    --jq '[.[] | select(.headRefName | startswith("delta/"))] | length' \
    2>/dev/null || echo "0")
  (( open_delta_prs > 0 )) && return 0

  local backlog_ready; backlog_ready=0
  if [[ -f "${REPO_ROOT}/.delta/BACKLOG.md" ]]; then
    backlog_ready=$(grep -c "^- \[ \]" "${REPO_ROOT}/.delta/BACKLOG.md" || true)
  fi
  (( backlog_ready == 0 )) && return 0

  add_gap "Delta failed when it should have run" \
    "Delta workflow failed at ${run_created_at} with no open delta PRs and ${backlog_ready} Ready backlog item(s). Check the workflow run logs for the root cause."
}

# Rule 3: Merge window expired but PR not merged
check_merge_window_expired() {
  local prs
  prs=$(gh pr list --state open --label "merge/ready" \
    --json number --jq '.[].number' 2>/dev/null || echo "")
  [[ -z "$prs" ]] && return 0

  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue

    # Skip PRs that are intentionally blocked — merge/blocked + merge/ready is expected state
    local is_blocked
    is_blocked=$(gh pr view "$pr" --json labels --jq '[.labels[].name] | contains(["merge/blocked"])' 2>/dev/null || echo "false")
    [[ "$is_blocked" == "true" ]] && continue

    local labeled_at
    labeled_at=$(gh api --paginate "repos/{owner}/{repo}/issues/${pr}/events" 2>/dev/null \
      | jq -rs '[.[][] | select(.event == "labeled" and .label.name == "merge/ready")] | max_by(.created_at) | .created_at // empty' \
      || echo "")
    [[ -z "$labeled_at" ]] && continue

    local labeled_epoch; labeled_epoch=$(date -d "$labeled_at" +%s)
    local elapsed; elapsed=$(( NOW_EPOCH - labeled_epoch ))
    local elapsed_hours; elapsed_hours=$(( elapsed / 3600 ))
    (( elapsed <= GRACE_SECONDS )) && continue

    local ci
    ci=$(gh pr view "$pr" --json statusCheckRollup \
      --jq '.statusCheckRollup // [] | if length == 0 then "none" elif any(.[]; .conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") then "failure" else "ok" end')
    [[ "$ci" == "failure" ]] && continue

    local mergeable
    mergeable=$(gh pr view "$pr" --json mergeable --jq '.mergeable')
    [[ "$mergeable" == "CONFLICTING" ]] && continue

    add_gap "Merge window expired without merge — PR #${pr}" \
      "PR #${pr} has had \`merge/ready\` for ${elapsed_hours}h (48h grace exceeded). CI: ${ci}, mergeable: ${mergeable}. Merge agent may not be running or lacks required permissions."
  done <<< "$prs"
}

# Rule 4: Council approved but merge/ready not applied
check_council_approved_missing_merge_ready() {
  local prs
  prs=$(gh pr list --state open --label "council/approved" \
    --json number,labels \
    --jq '.[] | select(
      (.labels | map(.name) | contains(["merge/ready"]) | not) and
      (.labels | map(.name) | contains(["merge/blocked"]) | not)
    ) | .number' 2>/dev/null || echo "")
  [[ -z "$prs" ]] && return 0

  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    add_gap "Council approved but \`merge/ready\` not applied — PR #${pr}" \
      "PR #${pr} has \`council/approved\` but is missing both \`merge/ready\` and \`merge/blocked\`. The Council→Merge integration hook may not be installed. Run \`bash merge/scripts/setup.sh\` to patch."
  done <<< "$prs"
}

# Rule 5: Delta PR awaiting Council review for >24h
check_council_review_overdue() {
  local pr_data
  pr_data=$(gh pr list --state open --label "delta" \
    --json number,createdAt,labels \
    --jq '.[] | select(
      (.labels | map(.name) | (contains(["council/approved"]) or contains(["council/needs-revision"])) | not)
    ) | (.number | tostring) + " " + .createdAt' 2>/dev/null || echo "")
  [[ -z "$pr_data" ]] && return 0

  while IFS=' ' read -r pr created_at; do
    [[ -z "$pr" ]] && continue
    local created_epoch; created_epoch=$(date -d "$created_at" +%s)
    local age; age=$(( NOW_EPOCH - created_epoch ))
    local age_hours; age_hours=$(( age / 3600 ))
    (( age <= REVIEW_SECONDS )) && continue

    add_gap "Delta PR awaiting Council review — PR #${pr} (${age_hours}h)" \
      "PR #${pr} has the \`delta\` label but no Council review after ${age_hours}h. Council may not be installed or the council-review workflow is failing."
  done <<< "$pr_data"
}

# ─── Run all checks ───────────────────────────────────────────────────────────

check_delta_ran_when_should_skip
check_delta_failed_when_should_run
check_merge_window_expired
check_council_approved_missing_merge_ready
check_council_review_overdue

# ─── Report ───────────────────────────────────────────────────────────────────

if (( gap_count == 0 )); then
  echo "No gaps detected."
  exit 0
fi

echo "${gap_count} gap(s) detected — building report..."

# Build PR state table
pr_table=$(gh pr list --state open \
  --json number,title,labels,createdAt \
  --jq '.[] | "| #\(.number) | \(.title | .[0:50]) | \([.labels[].name] | join(", ")) | \(.createdAt[:10]) |"' \
  2>/dev/null || echo "| (error fetching PR list) | | | |")

# Call Claude for narrative — fall back to raw gaps if unavailable
local_prompt=$(cat "${SCRIPT_DIR}/../advisors/ledger/prompt.md")
claude_input=$(mktemp)
printf 'Today is %s.\n\n## Gaps detected\n\n%s\n## Open PRs\n| PR | Title | Labels | Date |\n|----|-------|--------|------|\n%s\n' \
  "${TODAY}" "${gap_text}" "${pr_table}" > "${claude_input}"
narrative=$(claude --print --model haiku -p "$local_prompt" < "${claude_input}") \
  || narrative="${gap_text}"
rm -f "${claude_input}"

# Open GitHub issue
gh issue create \
  --title "Pipeline gap — ${TODAY}" \
  --label "ledger/gap" \
  --body "## Summary
${gap_count} gap(s) detected in the last 24h pipeline cycle.

## Gaps

${narrative}

## Pipeline state
| PR | Title | Labels | Date |
|----|-------|--------|------|
${pr_table}

---
*Reported by [Ledger](https://github.com/derrybirkett/ledger)*"

echo "Issue opened."
echo ""
echo "=== Ledger check complete ==="
