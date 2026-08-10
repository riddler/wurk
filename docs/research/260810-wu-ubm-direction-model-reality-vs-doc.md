---
date: 2026-08-10T09:53:05-0600
researcher: Claude
git_commit: 76d82d3f53caa644e5cd0de461edc84ddf7ab972
branch: wu-ubm-direction-model-row
repository: wurk
beads_issue: wu-ubm
topic: "models.direction: reality vs docs/manifest.md"
tags: [research, manifest, models]
status: complete
last_updated: 2026-08-10
last_updated_by: Claude
---

# Research: models.direction - reality vs docs/manifest.md

**Date**: 2026-08-10T09:53:05-0600
**Git Commit**: 76d82d3f53caa644e5cd0de461edc84ddf7ab972
**Branch**: wu-ubm-direction-model-row
**Bead**: wu-ubm

## Research Question

`docs/manifest.md`'s per-repo starting-values table listed `models.direction`
as `fable` for statifier-ex. Does statifier-ex's actual `.claude/wurk.json`
carry that value, and if not, what should the doc say?

## Summary

statifier-ex's `.claude/wurk.json` has no `models` section at all, so its
direction tier resolves to the loader default, `opus`. predicator-ex is the
same: no `models` section, default `opus`. Neither repo has ever shipped
`models.direction`. The doc's `fable` entry for statifier-ex recorded an
intent from phase 2 step 2 of the migration, not something either manifest
ever carried. `docs/manifest.md` has been corrected to describe what the two
repos' manifests actually contain today (wu-ubm).

Whether statifier-ex *should* set `fable` explicitly is a separate, open
question that this note exists to record - it is not something this repo can
decide on statifier-ex's behalf.

## Historical Context

`models.direction` was added to the schema during phase 2 step 2 of wurk's
migration, precisely because statifier-ex and predicator-ex were observed to
disagree on which model the direction tier should use (statifier: Fable;
predicator: Opus). `docs/manifest.md` recorded that intent in its annotated
example and in the per-repo table. The field never actually landed in
statifier-ex's `.claude/wurk.json` - the doc captured what was intended, not
what shipped, and the gap went unnoticed until wu-ubm.

The gap had a real consequence: predicator-ex's own adoption (px-ttt)
consulted this exact table row, was told `opus (default)` was correct, and
omitted the field - which happened to be right, but only because predicator
never diverged from the default, not because the table was accurate about
statifier.

## Open Questions

Does statifier-ex want `models.direction = fable` set explicitly in its own
`.claude/wurk.json`, or has that intent lapsed since phase 2 step 2 and
`opus` (the default it has been running on the whole time) is in fact fine?
If the answer is that `fable` is still wanted, a follow-up bead belongs in
statifier-ex's own tracker to add the one-line manifest field - not in wurk,
and not filed by this session.
