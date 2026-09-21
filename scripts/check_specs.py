#!/usr/bin/env python3
"""Check that docs/specs/ still describes the code it claims to describe.

Three kinds of problem, all of which make a spec directory worthless if left
unattended:

* structural  - a spec is missing front matter, a required section, or has
                duplicate / non-contiguous rule IDs;
* dangling    - a spec covers a file that no longer exists;
* stale       - the covered files have moved on since the spec was last
                reviewed (front-matter reviewed-at).

Usage:
    python3 scripts/check_specs.py            # report; exit 1 if anything is wrong
    python3 scripts/check_specs.py --bless    # stamp reviewed-at/on from HEAD

Blessing records the claim "I read this spec and it still describes the code".
It is worth exactly as much as that claim, so read before you bless.

Standard library only, in keeping with the rest of this repository.
"""

import datetime as dt
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC_DIR = os.path.join(REPO_ROOT, "docs", "specs")

REQUIRED_KEYS = ["id", "title", "status", "covers", "outputs", "tests",
                 "reviewed-at", "reviewed-on"]

REQUIRED_SECTIONS = [
    "Purpose",
    "Goals and non-goals",
    "Inputs",
    "Outputs",
    "Rules",
    "How it works",
    "Failure modes",
    "Tests",
    "Open questions",
]

UNSTAMPED = "unstamped"


def git(*args):
    try:
        out = subprocess.run(["git", "-C", REPO_ROOT] + list(args),
                             capture_output=True, text=True, check=False)
        return out.stdout.strip()
    except OSError:
        return ""


def full_sha(rev):
    """Resolve any revision spelling to a full sha, or '' if unknown."""
    if not rev or rev == UNSTAMPED:
        return ""
    return git("rev-parse", "--verify", "--quiet", rev + "^{commit}")


def split_front_matter(text):
    """Return (dict, body, raw_front_matter) or (None, text, '') if absent."""
    if not text.startswith("---\n"):
        return None, text, ""
    end = text.find("\n---\n", 4)
    if end == -1:
        return None, text, ""
    raw = text[4:end + 1]
    meta = {}
    for line in raw.splitlines():
        if not line.strip() or ":" not in line:
            continue
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return meta, text[end + 5:], raw


def paths_of(value):
    out = []
    for part in value.split(","):
        part = part.strip()
        if part and part.lower() != "none":
            out.append(part)
    return out


def check_rule_ids(body):
    """Rule IDs must be unique and contiguous from R1. Withdrawn ones count."""
    ids = [int(n) for n in re.findall(r"^\*\*~?~?R(\d+)", body, re.M)]
    problems = []
    if not ids:
        return ["no rules found (expected at least one **R1.**)"]
    dupes = sorted({n for n in ids if ids.count(n) > 1})
    if dupes:
        problems.append("duplicate rule ids: %s" % ", ".join("R%d" % n for n in dupes))
    expected = list(range(1, max(ids) + 1))
    missing = sorted(set(expected) - set(ids))
    if missing:
        problems.append("rule ids not contiguous, missing: %s"
                        % ", ".join("R%d" % n for n in missing))
    return problems


def check_spec(path, bless=False):
    """Return (list_of_problems, list_of_notes, changed_text_or_None)."""
    name = os.path.relpath(path, REPO_ROOT)
    with open(path) as fh:
        text = fh.read()

    meta, body, raw = split_front_matter(text)
    if meta is None:
        return ["%s: no front matter (must start with a --- block)" % name], [], None

    problems, notes = [], []

    for key in REQUIRED_KEYS:
        if key not in meta:
            problems.append("%s: front matter missing '%s'" % (name, key))
    if problems:
        return problems, notes, None

    # Sections: present, and in the prescribed order.
    found = re.findall(r"^## (.+?)\s*$", body, re.M)
    lowered = [s.lower() for s in found]
    for section in REQUIRED_SECTIONS:
        if section.lower() not in lowered:
            problems.append("%s: missing section '## %s'" % (name, section))
    ordered = [s for s in lowered if s in [r.lower() for r in REQUIRED_SECTIONS]]
    expected_order = [r.lower() for r in REQUIRED_SECTIONS if r.lower() in ordered]
    if ordered != expected_order:
        problems.append("%s: sections out of order (expected %s)"
                        % (name, " -> ".join(r for r in REQUIRED_SECTIONS)))

    problems += ["%s: %s" % (name, p) for p in check_rule_ids(body)]

    # Covered files must exist.
    covers = paths_of(meta["covers"])
    if not covers:
        problems.append("%s: 'covers' is empty - a spec that covers nothing cannot go stale" % name)
    missing = [p for p in covers if not os.path.exists(os.path.join(REPO_ROOT, p))]
    for p in missing:
        problems.append("%s: covers '%s', which does not exist" % (name, p))

    if meta.get("tests", "").lower() == "none":
        notes.append("%s: no tests declared" % name)

    # Staleness.
    live = [p for p in covers if p not in missing]
    new_text = None
    if live:
        head_of_covered = git("log", "-1", "--format=%H", "--", *live)
        reviewed = full_sha(meta["reviewed-at"])
        if bless:
            short = git("log", "-1", "--format=%h", "--", *live) or UNSTAMPED
            today = dt.date.today().isoformat()
            updated = raw
            updated = re.sub(r"^reviewed-at:.*$", "reviewed-at: " + short, updated, flags=re.M)
            updated = re.sub(r"^reviewed-on:.*$", "reviewed-on: " + today, updated, flags=re.M)
            if updated != raw:
                new_text = "---\n" + updated + "---\n" + body
        elif not reviewed:
            problems.append("%s: reviewed-at is '%s' - run --bless after reading it"
                            % (name, meta["reviewed-at"]))
        elif head_of_covered and reviewed != head_of_covered:
            behind = git("rev-list", "--count", "%s..%s" % (reviewed, head_of_covered))
            problems.append(
                "%s: STALE - %s commit(s) have touched %s since it was reviewed "
                "(reviewed at %s, code now at %s)"
                % (name, behind or "?", ", ".join(live),
                   meta["reviewed-at"], git("log", "-1", "--format=%h", "--", *live)))

    return problems, notes, new_text


def main():
    bless = "--bless" in sys.argv

    if not os.path.isdir(SPEC_DIR):
        print("No docs/specs/ directory.", file=sys.stderr)
        return 1

    specs = sorted(f for f in os.listdir(SPEC_DIR)
                   if f.endswith(".md") and not f.startswith("_")
                   and f != "README.md")
    if not specs:
        print("No specs found in docs/specs/.", file=sys.stderr)
        return 1

    all_problems, all_notes, blessed = [], [], []
    for fname in specs:
        path = os.path.join(SPEC_DIR, fname)
        problems, notes, new_text = check_spec(path, bless=bless)
        if new_text is not None:
            with open(path, "w") as fh:
                fh.write(new_text)
            blessed.append(fname)
        all_problems += problems
        all_notes += notes

    if bless:
        for f in blessed:
            print("blessed %s" % f)
        print("\nStamped %d spec(s). Now run the check without --bless." % len(blessed))
        return 0

    for note in all_notes:
        print("note: %s" % note)
    if all_problems:
        print()
        for p in all_problems:
            print("FAIL: %s" % p)
        print("\n%d problem(s) in %d spec(s)." % (len(all_problems), len(specs)))
        return 1

    print("%d spec(s) checked: structure OK, covered files present, none stale."
          % len(specs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
