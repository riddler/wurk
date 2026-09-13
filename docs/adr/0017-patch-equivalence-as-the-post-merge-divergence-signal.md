# ADR-0017: Patch equivalence as the post-merge divergence signal

Status: accepted (2026-09-12)

## Context

`request_state.rb:12-44` settles, with measurements on both forges, that
git ancestry is never the merge signal: a rebase-merged branch's tip is
never an ancestor of the target, so "ask git" silently no-ops forever while
looking like it works. The rule that follows is "ask the forge, never git",
and `skills/wurk:cleanup/SKILL.md:17-37` restates it as policy. ADR-0006
fixes the contract every kit script sits inside: system Ruby 2.6, stdlib
only, one JSON envelope, `--dry-run` on every mutating script, every
shell-out through `lib/sh.rb`.

`worktree_cleanup.rb` used a second, narrower git check downstream of the
forge call: once the forge said a request was merged, the script compared
the worktree's local `HEAD` against the request's recorded head sha
(`head_oid`, which is `mr.sha`) and refused to remove the worktree unless
they matched exactly. This was not a merge check - the forge had already
answered that - it was a "does this worktree still hold what merged"
check, meant to catch a worktree with unlanded commits on top of an
otherwise-merged branch.

That equality check breaks under any history rewrite between the local tip
and the recorded head. GitLab's server-side rebase (the Rebase button,
`glab mr rebase`, or an `ff`/`rebase_merge` merge that rebases first)
rewrites the source branch ref in place, so a clean, fully merged worktree
holding the pre-rebase sha compares unequal to the post-rebase `head_oid`.
Reproduced live on gitlab.com under wu-mya.6 (2026-09-12): the MR's sha
moved from `f1703cd4` to `8fb61078` while the MR was still `state:
"opened"`, and the sweep reported `"commits after merge (f1703cd4b71f...
!= 8fb61078844...), skipped"` with `data.beads_to_close == []` - the
worktree kept forever and its bead never even gathered, because the skip
returned before `beads_for` ran. The same inequality follows from a
re-push that amends, from `/wurk:refresh` rebasing a live worktree after
the request opened, or from an operator restacking a chain; it is not
GitLab-specific.

`skills/wurk:cleanup/SKILL.md:205-220` already told an operator how to
settle this inequality by hand, with exactly the probe this ADR adopts:

```
git -C <worktree> status --porcelain        # must be empty
git cherry <default-branch> HEAD            # every line must start with "-"
```

The research into what `request_state.rb` and its GitLab adapter actually
return (`docs/research/260817-wu-mya.2-gitlab-merged-request-detection.md`)
settled that `head_oid` tracks the source branch tip exactly and that the
MR's own commit-list endpoint returns the pre-rebase view - so neither
field can be re-read differently to make the equality check correct; the
comparison itself needed to change.

## Decision

**The forge's merged state remains the only merge signal.** Nothing here
changes what establishes that a request merged - `Forge::REQUEST_MERGED`,
queried once per worktree, decides that, exactly as `request_state.rb`'s
header requires. This ADR governs a check that runs only after that
question is already answered yes; git is not given a vote on whether
something merged.

**A sha inequality is decided by patch-id containment against the
manifest's remote default branch, not treated as proof of unlanded work.**
When the local `HEAD` differs from `head_oid`, `worktree_cleanup.rb` runs
`git cherry <manifest.remote_default_branch> HEAD` in the worktree. Empty
output, or every line starting with `-`, means every local commit has a
patch-equivalent already on the default branch, and the worktree is
removed. Any `+` line means at least one commit's change is not on the
default branch under any sha, and the refusal stands, worded exactly as
before (`"commits after merge (<local> != <head_oid>), skipped"`). A
non-zero exit from the probe itself is treated as unknown, which also
refuses, with a warning naming why - "could not tell" must never read as
"nothing left".

This is not the ancestry check `request_state.rb` bans, in two respects
that are worth restating here since they are the whole argument for why
this script is not back on the wrong side of that line:

- *Direction.* The banned check used ancestry to *establish* a merge; its
  failure mode is a false negative that silently stops cleanup from ever
  running. Here the forge has already established the merge, and git is
  consulted only to *refuse* a removal the forge already authorized; its
  failure mode is a worktree kept - visible in the sweep's own report and
  repairable by hand, which is the direction `skills/wurk:cleanup/SKILL.md
  :205-220`'s manual procedure already sanctioned.
- *Power.* Plain ancestry (`merge-base --is-ancestor HEAD
  origin/<default>`) is exactly what fails on a rebase-merged branch,
  because the replayed commits carry new shas. `git cherry` matches on
  patch id instead, so it answers correctly in precisely that case, and it
  subsumes plain ancestry: when a tip is an ancestor, `upstream..HEAD` is
  empty and `git cherry` prints nothing at all.

**The sweep fetches once, before the check phase, including on a dry
run.** `git cherry` can only see commits reachable from
`origin/<default>` in the local object store, so the probe needs current
remote-tracking refs to be correct rather than to silently reproduce the
bug it exists to fix on a stale checkout. The fetch moved from after the
per-worktree loop to before it, and it now also runs when
`worktree_cleanup.rb` is invoked with `--dry-run`, because
`/wurk:cleanup`'s check phase selects candidates on the dry run and the
real removal is only ever invoked by name for a candidate that phase
already named - the two have to decide against the same refs, or a dry
run refuses a candidate the real removal would accept.

That dry-run fetch is bounded, and the bound is what keeps it inside
ADR-0006 rather than making `worktree_cleanup.rb` an exception to it
(ADR-0006's "Amendment (2026-09-13)" records the carve-out from the
rule's own side, with what still violates it):
`git fetch --prune` writes only remote-tracking refs under
`refs/remotes/`, mirroring what the remote already says. It creates,
moves, and deletes nothing under `refs/heads/`, nothing in any worktree,
and nothing in the tracker - the three things a dry run exists to promise
it will not touch. `skills/wurk:kit/REFERENCE.md`'s `--dry-run` section
and its kit-author checklist both carry this exact bound, so a future kit
author reading "executes nothing" also reads the one narrow exception and
why nothing wider than a remote-tracking-ref update qualifies for it.

## Consequences

- The named failure modes of the probe all resolve to a refusal except
  one: a squash-on-merge of a multi-commit branch (no individual local
  commit's patch matches, so every line is `+`, refusing exactly as the
  old equality check did, since the shas differed there too); a rebase
  that resolved conflicts (the replayed diff genuinely differs, so `+` is
  correct); an empty local commit (unmatched, refusal stands); and a stale
  or failing probe, whether from a missed fetch or no network (unknown,
  refusal stands, with a warning naming why).
- The one accepted false-removal shape: a local commit that is
  patch-identical to an upstream commit but differently worded is treated
  as landed, and its message is lost with the branch (reflog aside). The
  change itself is on the default branch either way, so the loss is
  bounded to commit-message wording on a branch whose work merged.
  Tightening the match (also comparing subjects) was rejected as a
  heuristic layered on a heuristic, with its own false refusals on
  amended trailers.
- The identical failure shape on the GitHub side - any local history
  rewrite after a PR's recorded head sha - is fixed by the same probe with
  no adapter. The check runs entirely in git, downstream of whichever
  forge adapter answered "merged", so it does not branch on `forge.kind`
  and needs no GitHub-specific counterpart.
- `data.results[].result` gains one new wording for a probe-backed
  removal ("local tip rewritten, patches already on
  `<remote_default_branch>`") and one for an unverifiable probe
  ("commits after merge (...), unverified, skipped"), alongside the
  unchanged refusal string; `skills/wurk:cleanup/SKILL.md`'s result
  vocabulary matches all three.

## Alternatives rejected

- **Ask the forge which shas the request ever had** (GitLab's
  `/merge_requests/:iid/versions`, which records a `head_commit_sha` per
  diff version). Exact, with no patch-id heuristic and no fetch-freshness
  dependency, but rejected on three grounds. There is no comparable GitHub
  path - it would need force-push timeline archaeology through GraphQL,
  and `Forge::IMPLEMENTED`'s header comment in `lib/forge.rb` treats a
  capability that works on one forge and half-works on the other as worse
  than one that names the gap and stops,
  so this would be a two-adapter change plus a network call per diverged
  worktree plus a new unavailable-degradation path. It is also narrower
  where it matters: it answers "was this exact sha ever the branch head on
  the forge", which would refuse a local rebase done after the push
  (`/wurk:refresh`, an operator restack) even though every patch
  landed - and the SKILL.md procedure this ADR formalizes already treats
  that case as safe to remove. And it would leave the identical
  GitHub-side failure unfixed until a second adapter landed.
- **Compare local commits against the request's own commit list**
  (`beads_for_pr_on_gitlab` in `request_state.rb` already fetches this).
  Rejected because that endpoint returns the pre-rebase MR-side view, so in
  the rebased shape it returns exactly the shas the local branch already
  has - confirming
  equality with the thing already known and saying nothing about whether the
  work landed. Matching on message text instead of sha would be a heuristic
  that passes for any two commits sharing a subject.
- **Drop the check and rely on git's own refusals.** Not available:
  `git worktree remove` only refuses a dirty tree, and the branch delete
  is `-D` by necessity because a rebase-merged branch is never
  `-d`-deletable. This check is what makes `-D` safe, so removing it
  removes the only thing standing between a merged-by-the-forge worktree
  and a branch-delete of unlanded work.
- **Ask the forge for merged-request state, or the forge's file list, in
  place of a git-side check entirely.** Rejected as a restatement of the
  same problem this ADR solves: the forge's merge signal already ran and
  said yes; what remains is a local-worktree question (does this checkout
  still hold exactly what merged, or something rewritten, or something
  extra) that only the local object store can answer. Routing it back
  through the forge is the rejected "which shas did this request ever
  have" option above under a different name.
