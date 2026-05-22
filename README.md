# Ledger

Autonomous pipeline audit agent for GitHub repos. Part of [DeltaSuite](https://github.com/derrybirkett/deltado).

Runs at 8am UTC daily. Checks whether the pipeline (Delta, Council, Merge) did what it was supposed to do overnight. Silent on success — opens a `ledger/gap` issue when something diverged.

## How it works

1. Five deterministic rules check every pipeline handoff point
2. If any gaps are found, Claude writes a plain-English diagnosis for each
3. A `ledger/gap` GitHub issue is opened with the full report
4. If no gaps: silent exit, no issue

## Gap types monitored

| Rule | Description |
|------|-------------|
| Delta ran when it should have skipped | Delta opened a PR despite existing open delta PRs |
| Delta failed when it should have run | Delta failed with no open PRs and a non-empty backlog |
| Merge window expired | PR had `merge/ready` for >48h but wasn't merged |
| Council approved, `merge/ready` missing | `council/approved` without `merge/ready` or `merge/blocked` |
| Council review overdue | Delta PR open >24h with no Council review |

## Installation

```bash
# 1. Add submodule
git submodule add https://github.com/derrybirkett/ledger ledger

# 2. Add workflow
cp ledger/.github/workflows/ledger.yml .github/workflows/ledger.yml

# 3. One-time setup (creates ledger/gap label)
bash ledger/scripts/setup.sh
```

**Required secret:** `ANTHROPIC_API_KEY` (already set if using any other DeltaSuite component)

## Labels

| Label | Meaning |
|-------|---------|
| `ledger/gap` | Pipeline gap detected — human review required |

## DeltaSuite

Ledger is designed to work standalone, but pairs with:
- [Delta](https://github.com/derrybirkett/delta) — builds features autonomously
- [Council](https://github.com/derrybirkett/council) — AI CTO review gate
- [Merge](https://github.com/derrybirkett/merge) — autonomous PR merging

When all four are installed, the complete accountability loop is:
**Delta builds → Council reviews → Merge ships → Ledger audits**
