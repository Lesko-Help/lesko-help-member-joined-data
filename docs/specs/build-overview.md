---
id: build-overview
title: Overview builder
status: current
covers: scripts/build_overview.py
outputs: docs/data.json, docs/index.html, docs/artifact.html
tests: none
reviewed-at: 66e0482
reviewed-on: 2026-09-21
---

# Overview builder

## Purpose

Turns the pile of daily snapshots into the four things anyone actually wants to
know: how many members joined each day, how many of them ever showed up, who
left and how long they had been around, and what that does to the running
total. It is a pure function of `data/snapshots/` plus optional backfill — it
makes no network calls and holds no state, so deleting its outputs and
rebuilding is always safe.

## Goals and non-goals

**Goals**

- Derive the entry signal that no single API call can provide, by comparing
  snapshots across days.
- Produce numbers that tie exactly to the snapshot counts, with no drift.
- Be honest about precision: values that are upper bounds are marked as such.

**Non-goals**

- Fetching anything. See [fetch-members](fetch-members.md).
- Persisting derived state. Every run recomputes from raw snapshots; there is no
  incremental cache to go stale.
- Being correct about events that happened before tracking began. Pre-tracking
  history is *provided*, not *observed*, and is labelled that way (R10).

## Inputs

| Input | Source | Shape | Required |
|-------|--------|-------|----------|
| Snapshots | `data/snapshots/*.csv` | One file per day, named `YYYY-MM-DD.csv` | Yes — but an empty set is handled (R12) |
| Provided history | `data/backfill/monthly.csv` | `month,joined,left` with `month` as `YYYY-MM` | No |

## Outputs

| Output | Destination | Shape | Guarantee |
|--------|-------------|-------|-----------|
| Data | `docs/data.json` | `meta`, `totals`, `rows`, `groups`, `leavers`, `leaver_groups`, `leaver_totals`, `churn`, `analytics` | Complete; the HTML is a rendering of exactly this |
| Overview app | `docs/index.html` | Self-contained HTML, no external assets | Published to Netlify |
| Artifact form | `docs/artifact.html` | Same app without the document shell | — |

## Rules

### Membership and entry

**R1.** A member has **entered** once any snapshot has reported a non-empty
`last_visited` for them. The recorded entry date is the *first such value ever
observed*, clamped upward to the join date — a last-visit earlier than the join
date is impossible and is taken as the join date.

**R2.** The **signal baseline** is the date of the first snapshot containing a
non-empty `last_visited` for any member (2026-08-19). Before it, the absence of
an entry value carries no information.

**R3.** A cohort whose entire ten-week window closed before the signal baseline
MUST render blank week cells rather than zeros. Zero would assert that nobody
entered; blank asserts that it is unknowable.

**R4.** A member has **left** on the date of the first snapshot from which they
were absent, where "first" means the snapshot immediately after the last one
they appeared in. A member present in the most recent snapshot has never left,
whatever gaps appear earlier in their history — a mid-history disappearance
followed by a reappearance is a data blip, not a departure and a rejoin.

**R5.** A member with no join date in any snapshot MUST be dropped entirely.

### Attribution and precision

**R6.** Tenure buckets are 30-day months: bucket *n* covers days
`30(n-1) … 30n-1` for *n* in 1…12, and bucket 13 is everything from 360 days.
These are not calendar months and MUST NOT be labelled as such.

**R7.** The cohort view covers a rolling 365 days with 10 week columns; the
leaver view starts one day after the first snapshot, because a departure cannot
be observed on the first day of tracking (R4 needs a predecessor).

**R8.** Churn is attributed to the month in which a change was **observed**, not
the month it occurred. With daily snapshots the error is at most one day, which
can move an event across a month boundary. This is a known and accepted
imprecision.

**R9.** The opening balance is the count of distinct `member_id` values in the
first snapshot. Every subsequent month's closing total is the previous total
plus joined minus left, so the running total ties exactly to the snapshot counts
by construction.

**R10.** Provided history is chained **backward** from the opening balance:
`start(M) = end(M) - joined(M) + left(M)`. Only months strictly before the
tracking start are used — inside the tracked period the snapshots are
authoritative and backfill rows MUST be ignored. The chain stops at the first
month whose `left` is unknown, and every month before that point reports joined
and left but no total.

### Output shape

**R11.** `docs/data.json` MUST contain everything the HTML displays. The page is
a rendering of the JSON, not a separate computation, so anything downstream can
consume the JSON and get identical numbers.

**R12.** With no snapshots at all, the build MUST still emit valid, empty
artifacts rather than failing. A fresh clone with no data must produce a working
page.

## How it works

1. `load_snapshots` reads every `data/snapshots/*.csv` in filename order,
   skipping any file whose name is not a date.
2. `fold_members` collapses the sequence into one record per member — join,
   entry (R1), first seen, last seen — and derives `left` (R4). It also finds
   the signal baseline (R2).
3. `build_cohort_days` produces one row per join-day over the lookback window,
   with ten cumulative week cells each marked `closed` / `started`, and `wk_na`
   set per R3.
4. `build_leaver_days` produces one row per day from tracking start + 1,
   bucketed by tenure (R6).
5. `build_churn` computes the opening balance and monthly rows (R9), then
   prepends provided history chained backward (R10).
6. `build_analytics` produces the year-over-year monthly comparison.
7. `group_days` nests day rows into year → month → ISO week, computing subtotals
   at each level with the supplied aggregator.
8. `main` writes `docs/data.json`, then renders `docs/index.html` and
   `docs/artifact.html` from the same context (R11).

## Failure modes

| Condition | Behaviour | Visible as |
|-----------|-----------|------------|
| No snapshots | Empty but valid outputs (R12) | `Built docs/ app: 0 cohort days …` |
| Exactly one snapshot | No leaver rows possible (R7) | Empty Leavers tab |
| Snapshot file misnamed | Silently skipped | Lower snapshot count than files on disk |
| Member missing a join date | Silently dropped (R5) | `members_tracked` below the snapshot row count |
| Backfill row with unparseable `joined` | That row skipped | Month absent from provided history |
| Backfill month with empty `left` | Chain stops there (R10) | Earlier months show joined/left but no totals |
| A snapshot goes partially empty | Mass false departures (R4) | Leaver spike. Prevented upstream by [fetch-members](fetch-members.md) R9, not here. |

## Tests

| Rule | Test | Status |
|------|------|--------|
| R1–R12 | — | **uncovered** |

No tests exist, and this is the module where that costs most: every rule above
produces a number that someone will read as fact. The highest-value additions,
in order:

1. **Golden fixture** — three or four hand-written snapshot CSVs covering a
   join, an entry, a departure, and a mid-history blip, with an expected
   `data.json`. One fixture pins R1, R4, R9 and R12 simultaneously and fails
   loudly on any accidental change to cohort maths.
2. `fold_members` (R1, R4, R5) directly — the blip case in R4 is the subtlest
   behaviour in the repository and is currently guarded by nothing.
3. `build_churn` backward chaining (R10) — the stop-at-unknown-`left` branch.
4. `tenure_bucket` (R6) — pure, table-driven, boundaries at 0, 29, 30, 359, 360.

## Open questions

- **R8's one-day attribution error is invisible in the output.** A month
  boundary crossing is never flagged. Worth marking, or is the imprecision small
  enough to leave undocumented on the page?
- **R3's blank-vs-zero distinction is load-bearing but only marked on the page**
  with `≈` and blank cells. `docs/data.json` exposes `wk_na`, but a downstream
  consumer that ignores it will silently read unknowns as zeros.
- **Pre-baseline entry dates are upper bounds** (R1 takes the first *observed*
  value, which for a member who entered before 2026-08-19 is whenever they
  happened to last visit). The page marks these `≈`. The JSON does not
  distinguish them.
