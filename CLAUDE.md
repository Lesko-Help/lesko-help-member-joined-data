# Lesko Help member cohort tracker

A self-updating pipeline: a GitHub Action snapshots the Mighty Networks member
list every morning, and a build step turns the accumulated snapshots into
`docs/index.html` and `docs/data.json`. See `README.md` for the story.

## Read the specs first

`docs/specs/` holds one spec per module. They are the source of truth for
**behaviour** — the code is the source of truth for implementation. Before
changing anything under `scripts/` or `.github/workflows/`, read the spec that
covers it:

| Spec | Covers |
|------|--------|
| `docs/specs/daily-snapshot.md` | `.github/workflows/daily-snapshot.yml` |
| `docs/specs/fetch-members.md` | `scripts/fetch_members.py`, `scripts/api_config.json` |
| `docs/specs/build-overview.md` | `scripts/build_overview.py` |

Each spec numbers its rules `R1`, `R2`, … Cite them. "This violates
build-overview R4" is reviewable; "this seems wrong" is not.

`docs/specs/README.md` defines the format and the nine required sections.

## The one rule that keeps this working

**When you change code a spec covers, update that spec in the same commit**,
then re-stamp it:

```sh
python3 scripts/check_specs.py --bless   # only after actually reading the spec
python3 scripts/check_specs.py           # exits 1 if anything is stale or malformed
```

The checker compares each spec's `reviewed-at` against the last commit touching
its covered files. Skipping this turns `docs/specs/` into decoration within a
month — `scripts/api_config.json` already carries a note that went stale on
2026-08-19 and sat there unnoticed.

## House rules

- **Standard library only.** Both scripts run on a bare `ubuntu-latest` runner
  with no `pip install` step. Do not add dependencies.
- **No personal data in the repository.** It is public. Snapshots carry the
  numeric member id and dates — never names, e-mail addresses or profile text
  (`fetch-members` R2).
- **Never hand-edit `docs/index.html`, `docs/data.json`, `docs/artifact.html`
  or anything in `data/snapshots/`.** They are generated. Change
  `scripts/build_overview.py` and rebuild.
- **A partial snapshot is worse than no snapshot** (`fetch-members` R9). Any
  fetch error must abort before writing.

## Commands

```sh
python3 scripts/build_overview.py    # rebuild docs/ from data/snapshots/
python3 scripts/check_specs.py       # verify specs match the code
scripts/spec.sh build-overview       # read a spec in the terminal
```

`scripts/fetch_members.py` needs `MIGHTY_API_TOKEN` and hits the live API; it
normally runs only in the Action.
