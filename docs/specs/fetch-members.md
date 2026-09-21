---
id: fetch-members
title: Member snapshot fetcher
status: current
covers: scripts/fetch_members.py, scripts/api_config.json
outputs: data/snapshots/YYYY-MM-DD.csv, data/api_discovery/report.json
tests: none
reviewed-at: 21a0dac
reviewed-on: 2026-09-21
---

# Member snapshot fetcher

## Purpose

Mighty Networks stores only each member's *last* visit, not their first, and its
dashboard only reaches back twelve months. This module takes one immutable
photograph of the member list per day and commits it, so that the history this
repository needs — when each member first appeared, and when their last-visit
value first became non-empty — can be reconstructed from the sequence of
photographs even though no single API call can provide it.

## Goals and non-goals

**Goals**

- Produce exactly one snapshot file per UTC day, permanently committed.
- Survive schema drift in the upstream API without a code change where possible.
- Keep personal data out of the repository.

**Non-goals**

- Computing anything. No cohort maths, no aggregation, no derived columns —
  that is [build-overview](build-overview.md). A snapshot is raw observation.
- Backfilling history. The API cannot provide it; see `data/backfill/README.md`.
- Retrying a failed day. A missing day is a permanent hole, handled by the
  three catch-up slots in [daily-snapshot](daily-snapshot.md), not by this script.

## Inputs

| Input | Source | Shape | Required |
|-------|--------|-------|----------|
| `MIGHTY_API_TOKEN` | Environment (Actions secret) | Bearer token string | Yes |
| API config | `scripts/api_config.json` | JSON; `kind`, `url`, `node_fields`, paging | No — absence selects discovery mode |
| Member list | `https://api.mn.co/admin/v1/networks/4022250/members` | Paged JSON, `items[]`, `per_page` max 100 | Yes |
| Preflight | `…/networks/4022250/me` | JSON | No — only when `preflight_url` is set |

## Outputs

| Output | Destination | Shape | Guarantee |
|--------|-------------|-------|-----------|
| Daily snapshot | `data/snapshots/YYYY-MM-DD.csv` | Header + one row per member; columns `member_id, join_date, last_visited, checklist_completed, updated_at` | Written only on a fully successful fetch (R9); deduplicated (R4); deterministically ordered (R5) |
| Discovery report | `data/api_discovery/report.json` | Sanitized probe results | Contains no token and no e-mail addresses (R12) |

## Rules

**R1.** Exactly one snapshot MUST exist per UTC day. The filename is the UTC
date at the moment of writing, not the date any API value refers to.

**R2.** A snapshot MUST contain only the numeric member id and dates. Names,
e-mail addresses and free-text profile fields MUST NOT be written to this
repository, which is public. This rule outranks any convenience.

**R3.** A field the API does not supply MUST be recorded as the empty string,
never omitted and never defaulted. "Absent" and "known to be empty" are the same
on the wire but must stay distinguishable across days: a later snapshot filling
a previously empty column is the entry signal that
[build-overview](build-overview.md) R1 depends on.

**R4.** `member_id` MUST be unique within a snapshot. On collision the first
occurrence wins and later ones are discarded.

**R5.** Rows MUST be sorted by `(join_date, member_id)`. The ordering is not
meaningful to any consumer; it exists so that a day with no membership change
produces a zero-line diff.

**R6.** A `member_id` arriving as a GraphQL global id (`gid://…/12345`) MUST be
reduced to its trailing segment, so ids stay comparable across API shapes.

**R7.** Dates MUST be normalized to `YYYY-MM-DD`. An ISO prefix is taken as-is;
a 10–13 digit value is read as a Unix epoch in seconds; anything else becomes
the empty string. `updated_at` is the exception — it keeps its first 19
characters as a full timestamp, because day-over-day movement of that value was
the fallback activity signal while the API had no last-visit field.

**R8.** Each entry in `node_fields` MAY list several candidate source paths; the
first one present in the member object wins. This is what let `last_visited`
begin working on 2026-08-19 with no code change when Mighty added the field.
New candidates SHOULD be added speculatively rather than waiting for the field
to appear.

**R9.** Any non-200 response, GraphQL `errors` array, or missing
`connection_path` / items list MUST abort the run with exit status 1 before any
snapshot is written. A partial snapshot is worse than no snapshot: it would be
indistinguishable from mass departure and would corrupt leaver detection
permanently.

**R10.** When `preflight_url` is set, a failed preflight MUST abort before any
paging begins.

**R11.** Consecutive page requests MUST be separated by `page_delay` seconds
(0.4 in the current config).

**R12.** While `scripts/api_config.json` is absent the script runs in discovery
mode: it probes candidate endpoints and writes a sanitized report. The token
MUST NOT appear in that report, and anything matching an e-mail pattern MUST be
redacted.

## How it works

1. Read `MIGHTY_API_TOKEN`; exit 1 if unset.
2. If `scripts/api_config.json` is missing, run discovery mode (R12) and stop.
3. Preflight the token against `preflight_url` (R10).
4. Page through the member list — `rest` mode follows `links.next`, then
   `meta.total_pages`, then a short page as the stop condition; `graphql` mode
   follows `pageInfo.endCursor`. Sleep `page_delay` between pages (R11).
5. Map each member object to the five output columns via `node_fields` (R8),
   normalizing ids (R6) and dates (R7).
6. Deduplicate (R4), sort (R5) and write `data/snapshots/<today>.csv` (R1).

## Failure modes

| Condition | Behaviour | Visible as |
|-----------|-----------|------------|
| Token unset | Exit 1 before any request | `ERROR: MIGHTY_API_TOKEN is not set.`; the workflow turns this into a notice, not a failure |
| Preflight rejects the token | Exit 1, no paging | `ERROR: preflight … returned HTTP 401` |
| Non-200 mid-paging | Exit 1, **no file written** | `ERROR: … returned HTTP 5xx` |
| DNS / TLS / timeout | Treated as status 0, so exit 1 | `TRANSPORT ERROR: …` |
| Member list not found in response | Exit 1, top-level keys logged | `ERROR: could not locate the member list` |
| Field renamed upstream | Column silently goes empty | No error — caught only by noticing the column emptied. See Open questions. |

## Tests

| Rule | Test | Status |
|------|------|--------|
| R1–R12 | — | **uncovered** |

No tests exist. The highest-value additions, in order:

1. `norm_date` (R7) — pure function, table-driven, trivial to cover.
2. `extract_row` (R6, R8) against a recorded member object — protects the
   candidate-path mechanism that makes R8 work.
3. `write_snapshot` (R4, R5) — dedup and ordering.

## Open questions

- **A renamed upstream field fails silently** (R8's cost). A column that was
  96% populated yesterday and 0% today is a schema change, not a mass exodus,
  and nothing currently notices. A post-write assertion comparing fill rates
  against the previous snapshot would catch it.
- **`checklist_completed` is empty in every snapshot to date** — the Admin API
  exposes none of the three candidate names. Keep or drop the column?
- **`updated_at` was captured as a fallback activity signal** while no
  last-visit field existed. That field now exists and is 96% populated, so the
  fallback is no longer needed. It is still collected.
