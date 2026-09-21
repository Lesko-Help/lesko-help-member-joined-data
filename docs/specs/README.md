# Module specs

One spec per module. Every spec answers the same nine questions in the same
order, so you can find what you need without reading the whole file, and so an
AI worker picking this up in six months gets structured context instead of
archaeology.

## The rules

**1. One spec per module.** A module is a thing with a name, an input and an
output — a script, a workflow, a data contract. `docs/specs/<id>.md`.

**2. Every spec has front matter.** Machine-readable, checked by
`scripts/check_specs.py`:

```
---
id: build-overview
title: Overview builder
status: current
covers: scripts/build_overview.py
outputs: docs/data.json, docs/index.html, docs/artifact.html
tests: none
reviewed-at: a1b2c3d
reviewed-on: 2026-09-21
---
```

`covers` is the point of the whole system. It binds the spec to real files.
`reviewed-at` is the commit those files were at when a human last confirmed the
spec still describes them. When the code moves ahead of that commit, the spec is
**stale** and the checker says so. That is the only thing standing between this
directory and the rot that already reached `scripts/api_config.json`.

**3. Every spec has these nine sections, in this order, spelled this way.**
The checker enforces it. A section with nothing to say says "None." — never
omit it, because an empty section is information ("this module has no failure
modes") and a missing one is a question.

| # | Section | Answers |
|---|---------|---------|
| 1 | `## Purpose` | Why does this exist? One paragraph. |
| 2 | `## Goals and non-goals` | What is it for, and what is it deliberately not for? |
| 3 | `## Inputs` | Table: what comes in, from where, in what shape, required or not. |
| 4 | `## Outputs` | Table: what goes out, to where, and what is guaranteed about it. |
| 5 | `## Rules` | Numbered normative statements, `R1`…`Rn`. The heart of the spec. |
| 6 | `## How it works` | The sequence, in prose or numbered steps. Enough to predict behaviour. |
| 7 | `## Failure modes` | What breaks, what happens when it does, what you will see. |
| 8 | `## Tests` | Table: which rule is covered by which test. Gaps listed as gaps. |
| 9 | `## Open questions` | Known unknowns, deferred decisions, things to revisit. |

A `## Change log` section is optional and goes last; git already has the
history, so only add entries that explain *why* a rule changed.

**4. Rules get stable IDs.** `R1`, `R2`, … numbered within the spec, never
renumbered once written. If a rule dies, mark it `~~R7~~ *(withdrawn 2026-09-21:
reason)*` and keep the number. Stable IDs are what let a test name say
`test_r4_leaver_requires_absence`, a code comment say `# R4`, and a future
conversation say "R4 is wrong" without anyone guessing which rule that is.

**5. Rules are normative, not descriptive.** Write "Exactly one snapshot MUST
exist per UTC day", not "the script usually writes one file a day". MUST /
MUST NOT / SHOULD / MAY, used deliberately. If you find yourself writing
"currently", you are describing an implementation detail, not a rule — put it in
*How it works*.

**6. When you change covered code, update the spec in the same commit.**
Then re-stamp:

```sh
python3 scripts/check_specs.py --bless    # stamps reviewed-at/on for every spec
python3 scripts/check_specs.py            # verify; exits non-zero if anything is off
```

Blessing without reading is how this directory becomes decoration. The stamp
means "I read this and it is still true", and it is worth exactly as much as
that claim.

## Writing a new one

```sh
cp docs/specs/_TEMPLATE.md docs/specs/my-module.md
$EDITOR docs/specs/my-module.md
python3 scripts/check_specs.py --bless && python3 scripts/check_specs.py
```

## Reading them in a terminal

```sh
scripts/spec.sh build-overview     # render and browse in w3m
scripts/spec.sh                    # index of all specs
```

## Current specs

| Spec | Covers | Status |
|------|--------|--------|
| [daily-snapshot](daily-snapshot.md) | `.github/workflows/daily-snapshot.yml` | current |
| [fetch-members](fetch-members.md) | `scripts/fetch_members.py` | current |
| [build-overview](build-overview.md) | `scripts/build_overview.py` | current |
