---
id: daily-snapshot
title: Daily snapshot workflow
status: current
covers: .github/workflows/daily-snapshot.yml
outputs: data/snapshots/, docs/
tests: none
reviewed-at: a10a586
reviewed-on: 2026-09-21
---

# Daily snapshot workflow

## Purpose

The scheduler that makes the whole thing self-updating, and the reason a missed
day is rare rather than routine. GitHub runs scheduled workflows on a
best-effort basis — they are delayed by hours under load and sometimes dropped
entirely — and a missed day leaves a permanent hole in leaver detection that no
later run can fill. This workflow trades three cheap scheduled slots for that
risk.

## Goals and non-goals

**Goals**

- Land one snapshot per day despite an unreliable scheduler.
- Cost nothing on the days the first slot succeeds.
- Never commit an empty or partial snapshot.

**Non-goals**

- Alerting. A day that fails all three slots produces no notification; the hole
  is visible only in the data. See Open questions.
- Backfilling a missed day. The API cannot reconstruct it.

## Inputs

| Input | Source | Shape | Required |
|-------|--------|-------|----------|
| `MIGHTY_API_TOKEN` | Actions secret | Bearer token | No — absence degrades to rebuild-only |
| Schedule | Three cron slots, 05:30 / 11:30 / 17:30 UTC | — | — |
| Manual run | `workflow_dispatch` | — | — |
| Existing snapshot | `data/snapshots/<today>.csv` | Presence only | — |

## Outputs

| Output | Destination | Shape | Guarantee |
|--------|-------------|-------|-----------|
| Snapshot commit | `data/snapshots/` + `docs/` | One commit `Snapshot YYYY-MM-DD` | Only when something changed (R5) |

## Rules

**R1.** A scheduled run MUST be a no-op when `data/snapshots/<today>.csv`
already exists. The later slots are catch-ups, not retries, and cost no API
calls on a normal day.

**R2.** A `workflow_dispatch` run MUST proceed even when today's snapshot
exists, and it overwrites it. Manual invocation is an explicit instruction to
re-fetch.

**R3.** Runs MUST NOT overlap: `concurrency.group: snapshot` with
`cancel-in-progress: false`. A queued run waits rather than cancelling one that
may be mid-write.

**R4.** A missing `MIGHTY_API_TOKEN` MUST be a notice, not a failure. The fetch
is skipped, the rebuild still runs, and the workflow stays green — an
unconfigured repository is a valid state, not a broken one.

**R5.** The commit step MUST check `git diff --cached --quiet` and commit only
when something changed, so unchanged days leave no empty commits.

**R6.** The rebuild step runs on every needed run regardless of whether the
fetch ran, because `docs/` is a pure function of `data/` and may be stale for
reasons unrelated to today's fetch.

**R7.** The workflow needs `contents: write` and pushes to the default branch as
`lesko-cohort-bot`. It MUST NOT require any other permission.

## How it works

1. **Guard** — if today's snapshot exists *and* this is a scheduled run, set
   `needed=false` and every later step is skipped (R1, R2).
2. **Token check** — set `present=true/false`, emitting a notice when absent (R4).
3. **Fetch** — `python3 scripts/fetch_members.py`, only when needed and the token
   is present. Governed by [fetch-members](fetch-members.md).
4. **Rebuild** — `python3 scripts/build_overview.py`, whenever needed (R6).
   Governed by [build-overview](build-overview.md).
5. **Commit** — stage `data` and `docs`, commit and push only on a real diff (R5).

## Failure modes

| Condition | Behaviour | Visible as |
|-----------|-----------|------------|
| Slot 1 delayed or dropped | Slot 2 or 3 takes the snapshot | Commit timestamp later than 05:30 UTC |
| All three slots fail | **Permanent hole**; leaver detection for that day is lost forever | A missing date in `data/snapshots/`. Nothing reports it. |
| Token absent | Green run, rebuild only, no new snapshot | Actions notice |
| Fetch fails (any cause) | Job fails; no partial snapshot ([fetch-members](fetch-members.md) R9) | Red run |
| Two runs race | Second waits (R3) | Queued run in Actions |

## Tests

| Rule | Test | Status |
|------|------|--------|
| R1–R7 | — | **uncovered** |

CI workflows are awkward to unit-test and the guard logic is three lines of
shell, so the realistic coverage here is a **gap check** rather than a test: a
script that asserts `data/snapshots/` contains an unbroken run of dates from
2026-08-18 to yesterday, run on every build. That would convert R1's silent
failure mode into a visible one.

## Open questions

- **A total failure of all three slots is silent.** The hole is permanent and
  nothing announces it. A date-continuity assertion in the build (see Tests)
  would surface it the next day, when it is still worth knowing.
- **Three slots were chosen without measurement.** Now that 34 days of history
  exist, the commit times would show how often slot 1 actually misses, and
  whether three is too many or too few.
