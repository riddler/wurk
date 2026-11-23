---
date: 2026-09-15T13:47:33-0600
researcher: Claude
git_commit: e99173620641df3c547e1f920e271b401d1322db
branch: wu-1zu-sabotage-scan-worktree
repository: wurk
beads_issue: wu-1zu
topic: "gate.rb's sabotage scan anchors its diff on the manifest's checkout root, which is not the worktree being gated"
tags: [research, codebase, kit, gate, manifest, worktree]
status: complete
last_updated: 2026-09-15
last_updated_by: Claude
---

# Research: gate.rb's sabotage scan diffs the manifest's checkout, not the worktree

**Date**: 2026-09-15T13:47:33-0600
**Git Commit**: e99173620641df3c547e1f920e271b401d1322db
**Branch**: wu-1zu-sabotage-scan-worktree
**Bead**: wu-1zu

## Research Question

wu-1zu reports that when `gate.rb` runs in a git worktree, `Manifest#checkout_root`
resolves from the manifest's own location rather than the working tree, so
`sabotage_scan`'s `git diff` inspects whatever the main checkout has checked out
and never the worktree. The question this document answers, grounded in the
files: when does `checkout_root` diverge from the working tree, which of its
callers are anchored on the wrong thing, what does the documented contract
already promise, why was the current anchoring deliberately chosen, which tests
pin it, and what the candidate fixes are.

## Summary

The bug is real and reproduces. `Manifest#checkout_root`
(`skills/wurk:kit/scripts/lib/manifest.rb:262`) is defined as two directories
above the manifest file, so it is the root of *the checkout the manifest was
found in* - which is the working tree only when that working tree carries its
own `.claude/wurk.json`. `gate.rb:276` hands that path to `Sh.run` as the
`chdir:` for the sabotage `git diff`, and `gate.rb:286` uses it as the root for
the working-tree file reads behind the `# sabotage:` note check.

Two independent conditions make the manifest's directory differ from the
working tree, and the bead names only the first:

1. The `Manifest.locate` fallback (`manifest.rb:198-202`): the worktree carries
   no `.claude/wurk.json` and the walk-up finds none, so `main_checkout`
   (`manifest.rb:212-220`, `git rev-parse --git-common-dir`) supplies the main
   checkout.
2. The walk-up itself (`manifest.rb:224-234`) landing on an *ancestor*: a
   worktree nested under the main checkout (`worktrees_dir` inside the repo)
   walks up into the main checkout and finds its manifest. No fallback is
   involved, and the outcome is identical.

Both reduce to one statement, which is the useful framing for a fix: the bug
fires whenever the working tree does not carry its own manifest. It therefore
does not reproduce in `wurk` itself, where `.claude/wurk.json` is tracked
(`git ls-files .claude/` lists it, and `.gitignore` does not name `.claude/`),
so every worktree carries its own copy and `checkout_root == Dir.pwd`.

The failure mode is the worst available shape: not an error, but a silent false
clean. Worktrees share one object database, so the merge-base sha that
`BaseRef.merge_base` computes *in the worktree* resolves fine inside the main
checkout, the diff exits 0, and the envelope reports `scanned: true` with
`missing: []`. A gate that checked nothing reports itself as having verified
everything.

The anchoring is not an oversight but a deliberate choice made for a different
case. `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` introduced
`checkout_root` precisely to stop `gate.rb` resolving these paths against
`Dir.pwd`, because `gate.rb` is legitimately invoked from a subdirectory. That
plan's stated invariant (`:522-523`) is that "`Manifest.locate` walks up, so
`path` and therefore `checkout_root` are the same from any invocation
directory". The invariant holds within one checkout and fails across worktrees.
The two cases pull in opposite directions - for a subdirectory invocation
`Dir.pwd` is wrong and `checkout_root` right; in a worktree without its own
manifest `Dir.pwd` is right and `checkout_root` wrong - and
`git rev-parse --show-toplevel` is the one anchor that is correct for both,
verified below.

Nine of the eleven `checkout_root` resolution sites are affected, but most are
latent behind an optional manifest key. One site (`beads_dolt_remotes`) wants
the main checkout and is made *less* correct by a worktree anchor, so the
classification is three-way, not two-way.

## Detailed Findings

### 1. `checkout_root` and `Manifest.locate`: when each branch is taken

`Manifest#checkout_root` (`skills/wurk:kit/scripts/lib/manifest.rb:262-264`):

```ruby
def checkout_root
  File.expand_path(File.join(File.dirname(path), ".."))
end
```

It is a pure function of `path`. Its own comment (`manifest.rb:258-261`) states
the intent: "Every kit use of a repo-root-relative manifest path resolves
against this rather than Dir.pwd, because manifest resolution walks up from the
working directory (see `locate`) and gate.rb is legitimately invoked from a
subdirectory."

`Manifest.locate` (`manifest.rb:194-203`) has exactly two branches:

```ruby
def locate(start: Dir.pwd)
  found = walk_up(File.expand_path(start))
  return found if found

  main = main_checkout
  return nil unless main

  candidate = File.join(main, FILENAME)
  File.file?(candidate) ? candidate : nil
end
```

`walk_up` (`manifest.rb:224-234`) tests `<dir>/.claude/wurk.json` at every
level up to the filesystem root, first hit wins. `main_checkout`
(`manifest.rb:212-220`) shells out `git rev-parse --git-common-dir` and takes
its parent, which is the main working tree for every worktree of a repo.

So `checkout_root == <the working tree root>` if and only if the working tree
root itself holds `.claude/wurk.json` and it is the *first* hit on the walk up.
Three distinct outcomes, each reproduced empirically below:

| Case | `.claude/wurk.json` | Worktree location | `locate` branch | `checkout_root` |
|---|---|---|---|---|
| A | gitignored | sibling of main | `main_checkout` fallback | main checkout (WRONG) |
| B | tracked | sibling of main | `walk_up`, worktree's own | worktree (right) |
| C | gitignored | nested under main | `walk_up`, main's copy | main checkout (WRONG) |

Case C is not mentioned in the bead and matters for a fix: it is reached
without the `--git-common-dir` fallback ever running, so a fix that only
corrects the fallback branch would leave it broken.

#### Empirical reproduction

Built in a throwaway fixture (not in this repo). Case A: a repo whose
`.gitignore` names `.claude/`, one committed `test/a_test.rb` with a noted test,
a sibling worktree on branch `feature` whose commit adds
`def test_beta_unnoted` with no `# sabotage:` note, a manifest declaring
`gate.sabotage.test_roots: ["test/"]`. Running `gate.rb` from the worktree:

```
Dir.pwd            = <base>/repro/wt
manifest.path      = <base>/repro/main/.claude/wurk.json
checkout_root      = <base>/repro/main
show-toplevel      = <base>/repro/wt
checkout_root == pwd? false
```

and the envelope's `commands` trail shows the split anchoring exactly:

```
"git diff --name-only main...HEAD",            <- no chdir: the WORKTREE
"git status --porcelain",                       <- no chdir: the WORKTREE
"git merge-base main HEAD",                     <- no chdir: the WORKTREE
"(cd <base>/repro/main && git diff cc2794a3 -U0 -- test/)",   <- the MAIN CHECKOUT
"git status --porcelain",                       <- no chdir: the WORKTREE
```

with `"sabotage":{"enabled":true,"reason":null,"scanned":true,"missing":[],"unverifiable":[]}`
and `"ok":true`. The unnoted declaration was not found. Run in the worktree, the
same diff produces it:

```
@@ -2,0 +3,3 @@ end
+
+def test_beta_unnoted
+end
```

Case B (`.claude/wurk.json` tracked, wurk's own shape) reports
`missing: [{"file":"test/a_test.rb","text":"def test_beta_unnoted"}]` and emits
the `sabotage_note_missing` warning, i.e. correct behavior. Case C
(`.claude/` gitignored, worktree at `<main>/.wt/feature`) reports `missing: []`
with `manifest.path` in the main checkout, reached through `walk_up`.

Note what does *not* happen in cases A and C: the diff does not fail. The
merge-base sha is computed in the worktree but resolves in the main checkout
because both share the common object database, so `diff_res.success?` is true,
the `diff_failed` branch at `gate.rb:277-281` never fires, and no warning is
emitted. `scanned: true` with an empty `missing` list is exactly the claim
`gate.rb`'s own module doc (`gate.rb:60-67`) and the `diff_failed` handling are
written to avoid making falsely.

#### How a test reproduces it

The suite never runs real `git`. Every `git` call goes through `FakeSh`
(`skills/wurk:kit/scripts/test/support/fake_sh.rb:20`), installed as
`Sh.runner`, which raises `UnexpectedCommand` on any unregistered argv
(`fake_sh.rb:97-102`). No test in the suite runs `git init` or
`git worktree add` for real; every `git worktree add` string in
`worktree_create_test.rb` is an assertion about a *rendered* command.

That is sufficient, because `Manifest.main_checkout` shells out through `Sh.run`
with no `envelope:` (`manifest.rb:213`) and so is intercepted by the fake -
`support/manifest_helper.rb:50-53` already records this: "inside a bare one the
walk-up finds nothing and falls through to `git rev-parse`, which FakeSh
correctly refuses." A case-A fixture is therefore:

- `Dir.mktmpdir` giving `<d>`; write the fixture manifest at
  `<d>/main/.claude/wurk.json`; `mkdir <d>/wt` with no `.claude/` anywhere on
  its walk-up path (a `mktmpdir` path under `/tmp` has none);
- `@fake.expect(%w[git rev-parse --git-common-dir], out: "<d>/main/.git\n")`;
- `Dir.chdir("<d>/wt")` for the block.

That yields `checkout_root == <d>/main` while `Dir.pwd == <d>/wt`, with no real
git involved. `FakeSh::Call` records `chdir` (`fake_sh.rb:21`), so the assertion
is the same shape the existing subdirectory test already makes. Case C needs no
`--git-common-dir` stub at all: put the manifest at `<d>/.claude/wurk.json` and
chdir to `<d>/wt`, and the walk-up finds the ancestor copy. Prefix matching
means the `--git-common-dir` stub cannot collide with the base-ref ladder's
`["git","rev-parse","--verify","--quiet",...]` expectations, since matching is
`argv[0, prefix.length] == prefix`.

### 2. Every `checkout_root` resolution site, classified

Eleven sites resolve a path against `checkout_root`, counting the three methods
that default a `root:` keyword to it and the callers that take that default.
Three classifications are needed, not two: one site wants the main checkout.

| # | Site | What it resolves | Classification | Latent behind |
|---|---|---|---|---|
| 1 | `gate.rb:276` | `chdir:` for the sabotage `git diff` | incorrectly manifest-relative | `gate.sabotage` |
| 2 | `gate.rb:286` | root for the sabotage working-tree file reads | incorrectly manifest-relative | `gate.sabotage` |
| 3 | `gate.rb:523` | `gate_guard` ledger `File.exist?` (carve-out path) | incorrectly manifest-relative | `gate.guard_ledger` |
| 4 | `gate.rb:546` | same (gate-could-not-start path) | incorrectly manifest-relative | `gate.guard_ledger` |
| 5 | `gate.rb:574` | same (normal path) | incorrectly manifest-relative | `gate.guard_ledger` |
| 6 | `manifest.rb:451` default, via `gate.rb:364` | `chdir:` for the CONSUMER GATE COMMAND | incorrectly manifest-relative | `gate.cwd` |
| 7 | `manifest.rb:451` default, via `gate.rb:588` | `chdir:` for `gate.attest` | incorrectly manifest-relative | `gate.cwd` |
| 8 | `manifest.rb:451` default, via `gate.rb:547`, `:579` | the reported `data.gate_cwd` | incorrectly manifest-relative | `gate.cwd` |
| 9 | `manifest.rb:451` default, via `gate_run.rb:149` | `chdir:` for the detached long gate | incorrectly manifest-relative | `gate.cwd` |
| 10 | `manifest.rb:1657`, `:1662` | `File.directory?` on `artifacts.adr` | incorrectly manifest-relative (low severity) | `artifacts.adr` |
| 11 | `gate_run.rb:152` | WRITE destination `<root>/.claude/wurk-runs/gate/<id>` | correctly manifest-relative | - |
| 12 | `manifest.rb:700`, `:707`, `:716`, via `manifest.rb:1638`, `:1645` | `<root>/.claude/agents/<name>.md` reads | correctly manifest-relative | `mr.review_agents` |
| 13 | `manifest.rb:350` default, via `manifest.rb:1614` | `<root>/.beads/` footgun scan | wants the MAIN checkout (neither) | `beads.sync` lint |
| - | `worktree_create.rb:439-440`, `worktree_refresh.rb:161-162` | `gate_chdir(root: path)`, explicit | correctly anchored already | - |
| - | `worktree_create.rb:571` | `main_checkout_root`, a separate mechanism | n/a - precedent for a fix | - |

Per-site justification:

**1-2, the sabotage sites (`gate.rb:276`, `:286`).** The diff's pathspecs
(`gate.sabotage.test_roots` / `exempt_prefixes`, assembled at
`gate.rb:226-230`) and the note-check file reads
(`default_sabotage_file_reader`, `gate.rb:111-117`) are both questions about
*the tree whose branch is being gated*. Anchoring them on the manifest points
them at a different branch's content. This is the bead.

**3-5, the `gate_guard` ledger.** `gate_guard_from` (`gate.rb:335-347`) does
`File.exist?(File.join(root, ledger_path))`. `gate.guard_ledger` names a
tracked file in the tree (statifier's `docs/quality-gate-changes.md`), so
whether it exists is a property of the branch being gated. Its own comment
(`gate.rb:341-343`) states the subdirectory reason for the anchor, which is
correct for that case and wrong here. Severity is low in practice because the
ledger is long-lived and present in both trees; it misreports on a branch that
adds or removes it.

**6-7, the consumer gate command (`gate.rb:364`, `:588`).** The most serious
site. `gate_chdir` (`manifest.rb:451-453`) returns
`gate_cwd && File.join(root, gate_cwd)`, defaulting `root:` to `checkout_root`.
A consumer that declares `gate.cwd` and works in a worktree without its own
manifest runs its whole test suite in the main checkout - gating a tree nobody
asked about, and attesting the result. This is latent and self-cancelling for
everyone else: with `gate.cwd` absent, `gate_chdir` returns `nil`, `Sh.run`
passes no `chdir` (`lib/sh.rb:197`), and the command runs in `Dir.pwd`, which is
the worktree. Correct by accident, and the reason nobody has hit this.

**8, the reported `data.gate_cwd`.** A report of the wrong directory. Harmless
on its own, wrong for the same reason as 6-7.

**9, `gate_run.rb:149`.** The detached long-gate runner, same shape as 6-7 and
the same latency behind `gate.cwd`.

**10, the ADR directory (`manifest.rb:1657`).** `block_missing_adr_dir` checks
`File.directory?(File.join(manifest.checkout_root, dir))`. `artifacts.adr`
names a tracked directory, so its presence is a property of the branch. Low
severity: `docs/adr/` is long-lived, so both trees have it. It misjudges a
branch that introduces the directory for the first time, which is exactly the
commit the check exists to accept.

**11, `gate_run.rb:152`.** `File.join(manifest.checkout_root, ".claude", "wurk-runs", ...)`,
and the only WRITE among these. Classified correct: the path is a sibling of the
manifest inside the same `.claude/` directory, not a tracked tree path, and the
poller resolves it by the same rule, so the write and the read agree. Worth
naming in a plan as a deliberate behavior rather than an accident: under
worktrees this collects every run's state in one `.claude/wurk-runs/`, and a fix
that moved it would relocate a write.

**12, `mr_review_agent_*` (`manifest.rb:700-718`).** Reads
`<root>/.claude/agents/<name>.md`. The directory searched is a sibling of the
manifest file inside the same `.claude/`, so "the directory the manifest lives
in" is the semantic anchor, not an approximation of one. This is the clearest
correctly-manifest-relative family in the kit. `manifest.rb:1638` and `:1645`
take the default; the only explicit `root:` is in a test
(`manifest_test.rb:1904`).

**13, `beads_dolt_remotes` (`manifest.rb:350`).** The inverted case. It reads
two sources (`manifest.rb:336-349`): `.beads/config.yaml`, which is tracked and
so exists in every worktree, and `.beads/embeddeddolt/*/.dolt/repo_state.json`,
which is gitignored and exists only in the main checkout. The incident behind
`beads.sync` was a remote surviving in the second source after a guard removed
it from the first, so the second source is the point of the check. Measured in
this repo today:

```
checkout_root = <this worktree>
remotes (default root, i.e. this worktree):
  ["config.yaml: sync.remote -> .../johnnyt/wurk"]
remotes (main checkout):
  ["config.yaml: sync.remote -> .../johnnyt/wurk",
   "embeddeddolt/wu: origin -> .../johnnyt/wurk"]
```

So in `wurk` right now - where the tracked manifest makes `checkout_root` the
worktree, i.e. "correct" by the rule the other sites want - this footgun scan
silently misses the source it was written for. A fix that mechanically applies a
working-tree anchor to every site would make this site worse, not better. It
wants `Manifest.main_checkout`.

**The already-correct worktree callers.** `worktree_create.rb:439-440` and
`worktree_refresh.rb:161-162` both do
`manifest.gate_chdir(root: path) || path`, passing the worktree they are
operating on explicitly. They are the existing proof that the `root:` keyword is
the intended seam; the bug is confined to callers that take its default.

**The precedent.** `worktree_create.rb:571-581` already resolves a working tree
from git, through `Sh.run` with `envelope: env`, and already handles failure by
returning nil:

```ruby
def main_checkout_root(env)
  git_dir = Sh.run(%w[git rev-parse --git-dir], envelope: env)
  common_dir = Sh.run(%w[git rev-parse --git-common-dir], envelope: env)
  toplevel = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)
  return nil unless git_dir.success? && common_dir.success? && toplevel.success?

  is_main = File.expand_path(git_dir.out.to_s.strip) == File.expand_path(common_dir.out.to_s.strip)
  return nil unless is_main

  toplevel.out.to_s.strip
end
```

Its `--show-toplevel` call and its degradation shape are the template any fix
should follow. Note it uses the git-dir vs common-dir comparison as a
*main-checkout guard* (`worktree_create.rb:67-69` blocks `not_main_checkout`),
which is a different question from "what tree am I in" - a fix wants only the
`--show-toplevel` part.

**`--show-toplevel` satisfies both cases.** Verified: from
`<worktree>/skills/wurk:kit/scripts` it returns the worktree root, and from
`<fixture-worktree>/test` it returns the fixture worktree root. It is invariant
across subdirectories within a checkout - the property the wu-9fb plan needed -
and per-worktree correct, which is the property wu-1zu needs. No other anchor in
reach has both.

### 3. The internal inconsistency: `base_ref.rb` has no `chdir`

`lib/base_ref.rb` shells out five times and passes `chdir:` on none of them, so
every one runs in `Dir.pwd`:

- `resolve` -> `git rev-parse --verify --quiet <ref>` (`base_ref.rb:23`)
- `working_files` -> `git status --porcelain` (`base_ref.rb:37`)
- `untracked_files` -> `git status --porcelain` (`base_ref.rb:58`)
- `changed_files` -> `git diff --name-only <base>...HEAD` (`base_ref.rb:77`)
- `merge_base` -> `git merge-base <base> HEAD` (`base_ref.rb:99`)

`gate.rb` mixes the two anchors within a single invocation. Reading `gate.rb`'s
`run` (`gate.rb:452-528`) against the reproduction's `commands` trail:

| Call | Anchor | Which tree, case A |
|---|---|---|
| `BaseRef.changed_files` (`gate.rb:464`) | `Dir.pwd` | worktree |
| `BaseRef.merge_base` (`gate.rb:265`) | `Dir.pwd` | worktree |
| sabotage `git diff` (`gate.rb:276`) | `checkout_root` | main checkout |
| sabotage file reads (`gate.rb:286`) | `checkout_root` | main checkout |
| `BaseRef.untracked_files` (`gate.rb:241`, via `sabotage_untracked_unverifiable`) | `Dir.pwd` | worktree |
| ledger `File.exist?` (`gate.rb:344`) | `checkout_root` | main checkout |
| consumer gate command (`gate.rb:364`) | `gate_chdir`, nil or `checkout_root` | worktree if no `gate.cwd`, else main |

The concrete mixed results:

- **The base ref and the merge-base are the worktree's, the diff is the main
  checkout's.** The sha handed to `gate.rb:276` is `merge-base(main, worktree
  HEAD)`. Run inside the main checkout it diffs that sha against the *main
  checkout's* index and working tree. In case A the output was empty, because
  main is at the merge-base. Had main been on some third branch, the scan would
  have reported that branch's unnoted declarations against this bead - findings
  attributed to a branch nobody is gating.
- **The carve-out and the scan disagree about which tree changed.**
  `gate_applicable?` (`gate.rb:97-99`) runs off `changed_files`, i.e. the
  worktree, so the gate correctly decides it has something to measure; the
  sabotage scan then measures a different tree. `data.applicable: true` beside
  `sabotage.missing: []` reads as "there were changes and they were clean".
- **`unverifiable` is assembled from both trees.**
  `sabotage_untracked_unverifiable` (`gate.rb:238-244`) filters
  `BaseRef.untracked_files`, the worktree's untracked paths, while
  `scan_sabotage`'s `file_unreadable` and `declaration_not_found` entries come
  from reads under `checkout_root`. One list, two trees.
- **The note check can disagree with the diff that produced it.** The diff names
  a file and `default_sabotage_file_reader` reads that path under
  `checkout_root`. When both are the main checkout they agree; the failure is
  quieter than a mismatch would be, which is why nothing reports it.

`docs/manifest.md:664-669` records the reason `base_ref.rb` needs no `chdir`:
`git diff --name-only` and `git status --porcelain` "both print repo-root-relative
paths regardless of the process cwd". That is true about their *output format*
and says nothing about *which repository* answers. In one checkout the
distinction does not arise; across worktrees it is the whole bug.

### 4. The documented contract, and where it already disagrees

`docs/manifest.md`'s `gate.cwd` section opens (`:624-630`):

> The repo-root-relative directory the five consumer gate commands (`gate.full`,
> `gate.loop`, `gate.report`, `gate.report_loop`, `gate.attest`) run in. Absent
> (the common case) means they run at the root of the checkout being gated.
> Present, the resolved `chdir:` is `<root of the checkout being gated>/<gate.cwd>`
> - the checkout root for `gate.rb`, and the new (or refreshed) worktree's root
> for `worktree_create.rb` and `worktree_refresh.rb`.

Repeated at `:1050-1051`: "no `gate.cwd` means the gate commands run at the root
of the checkout being gated."

"The root of the checkout being gated" reads as the worktree. The clause that
follows equates it with "the checkout root for `gate.rb`", and the code reads
that as the manifest's checkout root. The doc never disambiguates the two, and
the sentence's own contrast makes the equation look deliberate: it distinguishes
`gate.rb`'s root from the worktree scripts' root, which tells a reader those
differ, without saying that `gate.rb`'s can itself be a different checkout from
the one it is running in.

The audit block is explicit about the mechanism and accurate about it
(`:677-683`):

> resolved on the filesystem or handed to git as a pathspec (root-relative,
> resolved against the manifest's checkout root, never the process cwd):
>   gate.guard_ledger existence - gate.rb gate_guard_from
>   gate.sabotage.test_roots / exempt_prefixes as `git diff` pathspecs -
>     gate.rb sabotage_diff_args
>   the working-tree file reads behind the `# sabotage:` note check -
>     gate.rb's default sabotage file reader

So the doc says "the manifest's checkout root" in one place and "the root of the
checkout being gated" in another, for the same three sites, and treats them as
the same thing.

**Where the doc and the code already disagree.** The Resolution section
(`:989-1006`) carries the premise the whole design rests on:

> 1. Walk up from the working directory looking for `.claude/wurk.json`. First
>    hit wins.
> 2. Failing that, ask git for the main checkout
>    (`git rev-parse --git-common-dir`, whose parent is the main working tree)
>    and look there.
>
> Walk-up comes first, rather than going straight to the main checkout as the
> plan originally leaned. A worktree is a full checkout and carries its own
> `.claude/wurk.json`, so walking up finds the manifest *on the branch being
> worked* - which is what makes a schema change testable on the branch that
> makes it. Reading main's copy instead would mean every manifest edit landed
> untested. Step 2 covers the case where the working directory is outside any
> checkout of the repo.

Two disagreements with the code, both load-bearing:

- **"A worktree is a full checkout and carries its own `.claude/wurk.json`"** is
  asserted as fact. It is true only when the consumer tracks the file. The bead's
  consumer gitignores `.claude/`, and for it the premise is false. Every
  "resolved against the manifest's checkout root" promise in the audit block is
  equivalent to "resolved against the worktree" *only under this premise*, so the
  doc is internally consistent and externally wrong at the same time.
- **"Step 2 covers the case where the working directory is outside any checkout
  of the repo."** Step 2 also fires, undocumented, for a working directory that is
  squarely inside a worktree of the repo and simply has no manifest above it.
  That is case A of the reproduction, and the doc gives a reader no reason to
  expect it.

Case C disagrees with nothing stated, because the doc never considers a worktree
nested under the main checkout; the walk-up's "first hit wins" silently crosses a
checkout boundary there.

`docs/gate-contract.md` describes tiers 0 through 3 and what each proves; it
makes no claim about the directory a gate runs in or the tree it measures, and
so neither contradicts nor supports the above. `docs/architecture.md:87-109`
places every project constant in the manifest and describes `lib/manifest.rb` as
"the single place that locates, parses, and validates the consumer repo's
`.claude/wurk.json`", without addressing path anchoring.

**The doc obligation.** CLAUDE.md's hard rule: "Keep `docs/manifest.md` and
`lib/manifest.rb` in sync; the code is authority, the doc must follow in the same
commit." Any fix touching `manifest.rb` carries a `docs/manifest.md` edit in the
same commit. At minimum the audit block at `:677-683` names the new anchor, the
`gate.cwd` section's "root of the checkout being gated" is disambiguated, and the
Resolution section's worktree premise at `:1001` is corrected - it is a factual
claim about consumers, not a design rationale, and it is the sentence a reader
would rely on to conclude there is no bug here. `docs/manifest.md` is not a dated
document, so it is edited rather than annotated.

### 5. History and prior intent

`docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` (dated; not to be
rewritten) is where `checkout_root` came from. Its Phase 2 overview
(`:232-238`):

> Phase 2 answers the bead's second half. The audit's finding is that the
> root-relative semantics are correct where they are matched against git
> *output*, and implicitly cwd-dependent at three sites that read the filesystem
> or feed git *pathspecs*. Introducing an explicit checkout-root concept in
> Phase 1 is what makes those three fixable rather than merely documentable, so
> Phase 2 anchors them on `Manifest#checkout_root` and records the
> execution-vs-matching contract in prose.

The three sites are exactly items 1, 2 and 3-5 of the table above. The problem
solved was `gate.rb` invoked from a subdirectory, where `Dir.pwd`-relative
resolution of a root-relative manifest path silently disagrees with a root
invocation - `test/gate_test.rb:40-43` restates this as "the Phase 2 regression
case".

On `gate_chdir`'s default (`:355`): "`gate_chdir` defaults its root to
`manifest.checkout_root`, not `Dir.pwd`, so a caller inside a subdirectory still
gets `<root>/<cwd>`." And on returning nil when the field is absent
(`:269-272`): "Returning nil rather than the root when the field is absent is the
key choice: it keeps the rendered `commands` audit trail byte-identical for every
consumer that does not use the field, so no existing envelope or test changes
shape." That choice is why sites 6-9 are latent rather than live for most
consumers.

The decisive passage is the plan's own manual-verification item (`:519-525`,
restated verbatim at `:860-866`):

> The same scratch repo, invoked with the process cwd **already inside** `sub/`:
> the gate still executes in `<root>/sub`, not `<root>/sub/sub`. This is the case
> `gate_chdir`'s default root exists for. It is structurally guaranteed -
> `Manifest.locate` walks up, so `path` and therefore `checkout_root` are the
> same from any invocation directory - but it is the one property whose breakage
> no test in either phase would catch, so check it by hand here rather than
> assuming it.

"`path` and therefore `checkout_root` are the same from any invocation
directory" is the invariant. It is true for invocation directories within one
checkout and false for invocation directories in different worktrees. The plan
flagged this as the one property no test would catch and moved it to manual
verification, which is precisely how it survived.

The plan mentions worktrees only in the sense of `worktree_create.rb` and
`worktree_refresh.rb` passing an explicit worktree `root:`
(`:51-54`, `:280-282`, `:374-397`, `:484-489`). It never considers `gate.rb`
itself running inside a worktree, and nowhere mentions `--git-common-dir`, a
gitignored `.claude/`, or the `Manifest.locate` fallback. Its "What We're NOT
Doing" (`:185-207`) rules out a filesystem probe of `gate.cwd` at validation
time - "A probe would also make validation depend on the process cwd, which is
the sensitivity gate.cwd exists to remove" - which is worth noting as a stated
aversion to cwd-dependent validation that a fix should not casually reintroduce.

Any fix must therefore keep the subdirectory case working. It is pinned by a
test (see item 6) and it was the entire point of the change being revised.

Two earlier dated documents bear on the scan itself:
`docs/research/260812-wu-4r7-sabotage-scope-pathspec.md` established the
pathspec form the diff uses, and
`docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` is the research behind
the plan above. `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md:111`
and `:254` record `gate_run.rb` picking up `manifest.gate_chdir` and the
`gate_chdir(root:)` signature, which is how site 9 entered the set.

### 6. Existing test coverage a fix must update

**`gate_test.rb:1827-1857`**, the test that names the exact mutation. Its note:

```ruby
# sabotage: drop `chdir: manifest.checkout_root` from the sabotage
# `git diff` call -> red (FakeSh records chdir nil, not the checkout root,
# and the file read behind the note check resolves against Dir.pwd instead
# of the root, missing the noted candidate below)
def test_sabotage_diff_and_file_reads_resolve_against_the_checkout_root_from_a_subdirectory
```

Fixture: `in_tmp_cwd(from_subdir: true)`, which delegates to `in_tmp_repo`
(`support/manifest_helper.rb:54-63`) - `Dir.mktmpdir`, copy
`test/fixtures/manifests/gate_tier1.json` to `<d>/.claude/wurk.json`, chdir
into `<d>` - and then creates `<d>/sub` and chdirs there instead
(`gate_test.rb:50-53`). So `checkout_root` is `<d>` and `Dir.pwd` is `<d>/sub`:
the manifest is in the same checkout, one level up. It writes the noted test
file at `<d>/test/foo_test.exs`, stubs the sabotage diff via
`expect_no_sabotage_diff` (`gate_test.rb:97-104`), and asserts

```ruby
assert_equal File.realpath(root), File.realpath(diff_call.chdir)
assert_equal [], env["data"]["sabotage"]["missing"]
```

`File.realpath` on both sides is explained at `:1850-1852`: `File.expand_path`
inside `checkout_root` resolves macOS's `/var -> /private/var` symlink where
`Dir.mktmpdir`'s raw path does not, and `realpath` makes them comparable without
either side caring.

Crucially this fixture cannot distinguish the two candidate anchors. `<d>` is
simultaneously the manifest's checkout root and what `git rev-parse
--show-toplevel` would report if git were real - so a fix that swaps the anchor
leaves the assertion true, provided the new `--show-toplevel` shell-out is
stubbed. The test's `# sabotage:` note would be the thing that goes stale: it
names `chdir: manifest.checkout_root`, which would no longer be the line. Per
CLAUDE.md the note must be rewritten to name the new mutation, and the test
renamed if `checkout_root` leaves its name. It must be updated, not deleted -
it is the only pin on the subdirectory behavior wu-9fb existed to create.

**`gate_test.rb:181-191`**, `test_sabotage_pathspec_uses_the_manifests_default_branch`,
carries the explanation of why these tests need a located manifest rather than
`with_manifest`:

> A real located manifest, not `with_manifest(manifest_with(...))`: the sabotage
> scan now resolves its `git diff` chdir and its file reads against
> `manifest.checkout_root`, which is two levels above `path` - for an in-memory
> manifest built from a fixture path, that is `test/fixtures`, not this test's
> tmp dir. Installing the modified raw at `<tmpdir>/.claude/wurk.json` keeps
> `checkout_root` aligned with `Dir.pwd`, the same as `in_tmp_repo`.

That is the constraint on any new fixture: an in-memory `manifest_with` has its
`path` in `test/fixtures/manifests/`, so its `checkout_root` is
`skills/wurk:kit/scripts/test`, and any code resolving against it reads real
repository files. `in_tmp_cwd` / `in_tmp_repo` is used 44 times in
`gate_test.rb`; all of those tests inherit `checkout_root == Dir.pwd`, which is
why none of them can see this bug.

**`manifest_test.rb:1088-1117`** pins the accessors directly:

```ruby
# checkout_root is two directories up from path (path is always
# <root>/.claude/wurk.json)
def test_checkout_root_is_two_directories_above_path
  ...
  assert_equal expected, m.checkout_root
```

then `test_gate_chdir_is_nil_when_gate_cwd_is_absent` (`:1101-1104`, asserting
nil for both the default and an explicit `root: "/some/worktree"`),
`test_gate_chdir_joins_gate_cwd_onto_the_default_checkout_root` (`:1107-1110`,
`assert_equal File.join(m.checkout_root, "backend"), m.gate_chdir`), and at
`:1112-1117` the note

```ruby
# sabotage: ignore the explicit root: keyword and always use checkout_root
# ... on: gate_chdir(root: <worktree path>).
def test_gate_chdir_joins_gate_cwd_onto_an_explicit_root
  assert_equal "/some/worktree/backend", m.gate_chdir(root: "/some/worktree")
```

These are unit tests over an in-memory manifest with no git and no filesystem
resolution, so they survive a fix that leaves `checkout_root` itself alone and
constrain any fix that changes it. `test_checkout_root_is_two_directories_above_path`
is the direct pin on approach (c) below.

**`manifest_test.rb:1407` and `:1774`** carry the comment "A throwaway checkout:
`<root>/.claude/wurk.json`, so `checkout_root` - and therefore the paths resolved
against it - is the tmpdir." These are the lint tests behind sites 10, 12 and 13;
they create directories and files but no git repository.

**What a worktree-reproducing fixture needs instead**, stated against the above:
the manifest must sit somewhere that is *not* `Dir.pwd`'s working-tree root, and
`Dir.pwd` must have a working-tree root of its own. `in_tmp_repo` cannot express
that, because it puts the manifest at the root it chdirs into. The recipe is in
item 1; the new helper is a sibling of `in_tmp_repo` rather than a change to it,
since 44 tests depend on the current shape.

**Tests that would need attention if the sabotage anchor changes:**

- `gate_test.rb:1827-1857` - the subdirectory test above; note and possibly name.
- `gate_test.rb:181-214` - the comment at `:185-191` names `checkout_root` as the
  reason for the fixture shape; the reason changes.
- `gate_test.rb:40-43` - `in_tmp_cwd`'s doc comment describes the `from_subdir`
  case in terms of `Manifest.locate`'s walk-up.
- `gate_test.rb:1651`, `:1678` - `# sabotage: drop chdir: manifest.gate_chdir from
  run_quality's Sh.run`, live if sites 6-7 change.
- `gate_test.rb:1790-1824` - the `gate_guard` ledger tests, live if sites 3-5
  change.
- `manifest_test.rb:1088-1117` - as above; only approach (c) breaks them.
- `manifest_test.rb:1867-1905` - `mr_review_agent_roots` notes, live only if a
  fix touches site 12.
- `worktree_create_test.rb:810`, `:845` and `worktree_refresh_test.rb:248`,
  `:280` - `# sabotage: pass chdir: path instead of chdir: gate_chdir(manifest, path)`.
  These pin the already-correct explicit-root callers and should stay green
  untouched; if one of them goes red, the fix has changed the `root:` seam itself.
- `contract_test.rb` - every new shell-out must go through `lib/sh.rb`, and
  `gate.rb` must acquire no write path.

A further consequence of the FakeSh design: if a fix adds a
`git rev-parse --show-toplevel` shell-out to a path `gate.rb` always takes, every
test that reaches it needs the stub or dies on `UnexpectedCommand`. That is a
large mechanical diff across `gate_test.rb` and any other suite whose script
resolves the new anchor, and it is a real cost input to choosing among the
approaches below. Resolving lazily (only when a site actually needs the path)
keeps it off the paths that never do.

### 7. Candidate approaches, with tradeoffs

Not a recommendation; the plan stage chooses.

**(a) A new accessor used by the sabotage sites only.** Add something like
`Manifest#work_tree_root` (or a `lib/` helper) that runs
`git rev-parse --show-toplevel` and falls back to `checkout_root`, and use it at
`gate.rb:276` and `:286` only.

- Fixes the bead exactly, smallest diff, smallest test churn - only tests that
  reach the sabotage scan need the new stub.
- Keeps the subdirectory case: `--show-toplevel` is invariant across
  subdirectories, verified in item 2.
- Leaves sites 3-5, 6-9 and 10 wrong. Sites 6-7 are arguably more severe than
  the bead (running a consumer's whole gate in the wrong tree), so this fixes
  the reported symptom and leaves a worse latent one, which a plan should state
  rather than discover later.
- Introduces a second root concept with two names and no stated rule for which
  to use. Mitigated only by documenting the rule.
- Doc obligation: the audit block at `docs/manifest.md:677-683` must split into
  two lists, since its three entries would no longer share an anchor.

**(b) The same accessor applied to every site classified incorrect.** Items 1-10.

- Fixes the bead and the worse latent bug together, and leaves one coherent rule:
  paths naming tracked content in the tree resolve against the working tree;
  paths naming siblings of the manifest inside `.claude/` resolve against the
  manifest.
- Site 13 must be excluded deliberately and re-anchored on
  `Manifest.main_checkout`, or left alone with the reason recorded. Sweeping it
  in makes it worse.
- Site 11 is a write; changing it relocates gate-run state and orphans any
  in-flight run's poll path. Leaving it alone is the conservative call and
  consistent with the rule above, but the plan should say so explicitly.
- Largest test churn: the `--show-toplevel` stub spreads to every test reaching
  `run_quality`, the ledger paths and the lint. Lazy resolution limits this.
- Behavior change for consumers with `gate.cwd` in a worktree without its own
  manifest: their gate starts running somewhere else. That is the fix, but it is
  a visible change and belongs in the plan's success criteria.
- Doc obligation: the largest. The `gate.cwd` section, the audit block, and the
  Resolution premise all move, in the same commit as `manifest.rb`.

**(c) Change `checkout_root` itself** to resolve from `--show-toplevel`, falling
back to the two-levels-up definition.

- One concept, every site fixed at once, nothing to remember.
- Breaks the two sites where the manifest's directory is the *correct* semantic
  anchor. Site 12 would search `<worktree>/.claude/agents/` while reading
  `<main>/.claude/wurk.json`, i.e. a directory whose manifest it is not honoring;
  site 11 would write run state into a tree that may be removed by
  `/wurk:cleanup` while a detached gate is still writing to it. Both would need
  an explicit opt-out, which reintroduces the two-concept problem from the other
  side.
- Makes `checkout_root` shell out. Today it is a pure string function called
  freely, including from `validate!`-adjacent lint code; every caller becomes
  git-dependent and FakeSh-visible, and `manifest_test.rb:1088-1094` becomes a
  test of a git-shelling method.
- Contradicts the wu-9fb plan's stated aversion to making resolution depend on
  the process environment (`:312-316`), and the accessor's own documented
  definition. Not forbidden - a plan may revise it - but it is the approach that
  owes the most argument.
- Doc obligation: the Resolution section and the audit block, plus a rename if
  "checkout root" stops describing what it returns.

**A fourth option worth pricing: fix `Manifest.locate` instead.** Have the
fallback, and the walk-up when it crosses a checkout boundary, prefer a manifest
in the current working tree, or at least record that the manifest came from a
different checkout so callers can branch on it. This addresses the root cause
rather than each consumer, and would make cases A and C behave like case B. It
is the largest blast radius of the four - every script's manifest resolution
changes - and it conflicts with the Resolution section's deliberate ordering
(`docs/manifest.md:1000-1006`), which exists so a manifest edit is testable on
the branch that makes it. Noted for completeness because the plan should reject
it explicitly rather than silently.

**Degraded behavior when `--show-toplevel` fails.** It fails when cwd is not
inside a git working tree (`fatal: not a git repository`), and can fail inside a
bare repository. The kit's envelope contract (`docs/architecture.md:49-58`,
exit 0/1/2, `blocked[]` with `needs: "human"`) admits three shapes, and the
precedent at `worktree_create.rb:571-581` is `return nil unless ...success?` with
the caller deciding:

- **Fall back to `checkout_root` and warn.** Matches `BaseRef.resolve`'s
  `stale_base_ref` precedent (`base_ref.rb:26-29`), which warns rather than
  blocking when it must use a knowably worse answer. Keeps `gate.rb` usable
  outside a repo. The argument against: a warning on a report-only scan is easy
  to skim past, and the whole failure being repaired is a silent false clean.
- **Block.** `env.block!(needs: "human")`, refusing to report a scan it cannot
  anchor. Strictest, and consistent with `gate.rb`'s existing treatment of a
  failed diff as "this scan checked nothing at all" (`gate.rb:259-261`). Against:
  a gate that cannot run outside a git repo is a new constraint, and `gate.rb`
  already reaches git through `BaseRef` on every invocation anyway, so in
  practice a non-repo cwd is already degraded.
- **Report it as `unverifiable`.** Add a `reason: "no_work_tree"` entry beside
  the existing `no_base_ref` and `diff_failed` entries (`gate.rb:266-281`), with
  `scanned: false`. This is the shape `gate.rb` already uses for exactly this
  class of blind spot, it does not flip `ok`, and it is the one option that makes
  the blind spot legible in the envelope without a new blocking condition. It
  costs a new `reason` value, which `/wurk:commit`'s reading of
  `data.sabotage.unverifiable` would want to know about.

Whichever is chosen, the shell-out goes through `lib/sh.rb` with
`envelope: env` so it appears in the `commands` trail (ADR-0006, enforced by
`contract_test.rb`), and the resolved path should be resolved once per invocation
and threaded, the way `changed` already is (`gate.rb:94-96`), rather than
re-shelled at each site.

## Code References

- `skills/wurk:kit/scripts/lib/manifest.rb:262-264` - `checkout_root`, two levels above `path`
- `skills/wurk:kit/scripts/lib/manifest.rb:194-203` - `locate`, walk-up then `main_checkout` fallback
- `skills/wurk:kit/scripts/lib/manifest.rb:212-220` - `main_checkout` via `git rev-parse --git-common-dir`
- `skills/wurk:kit/scripts/lib/manifest.rb:224-234` - `walk_up`, first hit wins, crosses checkout boundaries
- `skills/wurk:kit/scripts/lib/manifest.rb:350-356` - `beads_dolt_remotes`, the site wanting the main checkout
- `skills/wurk:kit/scripts/lib/manifest.rb:451-453` - `gate_chdir(root: checkout_root)`
- `skills/wurk:kit/scripts/lib/manifest.rb:700-718` - `mr_review_agent_*`, correctly manifest-relative
- `skills/wurk:kit/scripts/lib/manifest.rb:1614` - the dolt-remote lint caller, takes the default root
- `skills/wurk:kit/scripts/lib/manifest.rb:1654-1664` - `block_missing_adr_dir`
- `skills/wurk:kit/scripts/gate.rb:111-117` - `default_sabotage_file_reader(root)`
- `skills/wurk:kit/scripts/gate.rb:226-230` - `sabotage_diff_args`, the pathspec assembly
- `skills/wurk:kit/scripts/gate.rb:238-244` - `sabotage_untracked_unverifiable`, `Dir.pwd`-anchored
- `skills/wurk:kit/scripts/gate.rb:262-289` - `sabotage_scan`, both wrong anchors and the `chdir` comment
- `skills/wurk:kit/scripts/gate.rb:335-347` - `gate_guard_from`, the ledger `File.exist?`
- `skills/wurk:kit/scripts/gate.rb:360-373` - `run_quality`, the consumer gate command's `chdir`
- `skills/wurk:kit/scripts/gate.rb:452-528` - `run`, where the two anchors mix
- `skills/wurk:kit/scripts/gate.rb:588-589` - the `gate.attest` `chdir`
- `skills/wurk:kit/scripts/gate_run.rb:149-152` - the detached gate's `chdir` and its `run_dir` write
- `skills/wurk:kit/scripts/lib/base_ref.rb:23,37,58,77,99` - five shell-outs, no `chdir`
- `skills/wurk:kit/scripts/lib/sh.rb:96-98,195-197` - `chdir:` threaded to `Process.spawn`, omitted when nil
- `skills/wurk:kit/scripts/worktree_create.rb:439-440` - `gate_chdir(root: path)`, explicit and correct
- `skills/wurk:kit/scripts/worktree_create.rb:571-581` - `main_checkout_root`, the `--show-toplevel` precedent
- `skills/wurk:kit/scripts/worktree_refresh.rb:161-162` - the other explicit-root caller
- `skills/wurk:kit/scripts/test/gate_test.rb:40-58` - `in_tmp_cwd`, the `from_subdir` fixture
- `skills/wurk:kit/scripts/test/gate_test.rb:181-214` - why these tests need a located manifest
- `skills/wurk:kit/scripts/test/gate_test.rb:1827-1857` - the test naming the exact mutation
- `skills/wurk:kit/scripts/test/manifest_test.rb:1088-1117` - the accessor pins
- `skills/wurk:kit/scripts/test/support/manifest_helper.rb:49-63` - `in_tmp_repo` and the FakeSh note
- `skills/wurk:kit/scripts/test/support/fake_sh.rb:20-102` - `FakeSh`, `Call#chdir`, `UnexpectedCommand`
- `docs/manifest.md:622-684` - the `gate.cwd` section and the path-anchoring audit
- `docs/manifest.md:989-1006` - the Resolution section and its worktree premise
- `docs/manifest.md:1050-1051` - "the root of the checkout being gated", restated

## Architecture Documentation

The kit's script contract (`docs/architecture.md:43-67`, ADR-0006) settles the
mechanical constraints on any fix: stdlib-only system Ruby at the 2.6.10 floor,
one JSON envelope on stdout with exit 0/1/2, every shell-out through
`lib/sh.rb`, and `contract_test.rb` enforcing all of it. A new
`git rev-parse --show-toplevel` call is therefore an `Sh.run` with
`envelope: env` so it lands in the `commands` trail, and `gate.rb` must acquire
no write path (`gate.rb:60-67` and the contract test's guarded-write scan).

Two conventions bear directly on the shape of a fix. The `root:` keyword on
`gate_chdir`, `beads_dolt_remotes` and `mr_review_agent_*` is an existing seam
for "resolve against a tree I name rather than the one you inferred", already
used correctly by `worktree_create.rb` and `worktree_refresh.rb`; a fix can work
with that seam rather than against it. And `gate.rb`'s report-only discipline -
`missing` and `unverifiable` never flip `ok`, and a scan that could not run says
so rather than returning an empty list - is the established handling for the
degraded case, which is why `unverifiable` is a natural home for a
`--show-toplevel` failure.

CLAUDE.md's same-commit rule ties `lib/manifest.rb` to `docs/manifest.md`. Since
every candidate approach touches at least the audit block at
`docs/manifest.md:677-683`, every candidate carries a doc commit.

## Historical Context

- `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` - introduced
  `checkout_root`, `gate_cwd` and `gate_chdir`, and anchored the three
  filesystem/pathspec sites on `checkout_root` (`:232-238`). The subdirectory
  invocation was the problem being solved. Its manual-verification item at
  `:519-525` states the invariant that this bead falsifies, and explicitly notes
  that no test would catch its breakage.
- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` - the research behind
  that plan; the audit of every kit consumer of a repo-root-relative manifest
  path.
- `docs/research/260812-wu-4r7-sabotage-scope-pathspec.md` - established the
  sabotage diff's pathspec form (`test_roots` plus `:!exempt` prefixes) that
  `sabotage_diff_args` now builds.
- `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md:111,254` -
  records `gate_run.rb` adopting `manifest.gate_chdir`, which is how site 9
  joined the affected set.
- `docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:174` -
  decided against renaming `main_checkout` / `main_checkout_root`, so the two
  similarly-named mechanisms in item 2 are a deliberate coexistence.

These are dated documents and are not to be rewritten. Nothing in them needs
annotating for this bead: no identifier they name has been renamed or removed.
If a fix renames `checkout_root`, the definitional mentions at
`260817-wu-9fb-subdirectory-gate-cwd.md:248` and its Phase 2 overview become the
places a reader would grep, and each would take one inline `**Later (...):**`
pointer.

## Related Research

- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` - the direct predecessor
- `docs/research/260812-wu-4r7-sabotage-scope-pathspec.md` - the scan's pathspec scope
- `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md` - `gate_run.rb`'s adoption of `gate_chdir`

## Open Questions

No human was available during this research; these are recorded rather than
asked, and each is a decision for the plan stage.

1. **Scope.** Does wu-1zu fix only the two sabotage sites (approach a), or every
   incorrectly-anchored site (approach b)? Sites 6-7 - a consumer's whole gate
   command running in the wrong checkout - are plausibly more severe than the
   reported symptom, and both are latent behind `gate.cwd`. If the answer is "the
   sabotage sites only", the rest wants its own bead rather than silence.
2. **`beads_dolt_remotes` (site 13).** It is measurably degraded *today* in
   `wurk`, in the opposite direction from the bead: run from a worktree it misses
   the `embeddeddolt` source the check exists for. Is that in scope here, a
   separate bead, or accepted with a recorded reason? It is the one site a
   mechanical sweep would break.
3. **Degraded behavior.** Of the three shapes in item 7 - warn and fall back,
   block, or a new `unverifiable` reason - which does the kit want? A new
   `reason` value is a small contract addition that `/wurk:commit`'s reading of
   `data.sabotage.unverifiable` would need to tolerate.
4. **`gate_run.rb:152`'s write (site 11).** Classified correct here on the
   grounds that it is a `.claude/` sibling rather than tracked content, and that
   writer and reader agree. Under worktree-per-issue this centralizes run state
   in the main checkout. Is that intended? If a plan moves it, a detached run in
   flight during a `/wurk:cleanup` that removes the worktree is the failure to
   think about.
5. **The doc premise at `docs/manifest.md:1001`.** "A worktree is a full checkout
   and carries its own `.claude/wurk.json`" is false for the consumer in this
   bead. Should the fix also make it true - by having `/wurk:branch` or
   `worktree_create.rb` place a manifest in each new worktree, or by documenting
   that tracking `.claude/wurk.json` is a requirement rather than a convention -
   in addition to removing the code's dependence on it? That would be a
   consumer-facing requirement and is a larger decision than the bead states.
6. **Which consumer hit this.** The bead's framing ("falls back to
   git-common-dir when `.claude/` is gitignored") implies a specific consumer
   repo. Knowing which, and whether its worktrees are siblings (case A) or nested
   (case C), would confirm the reproduction matches the report. The fix covers
   both, so this does not block.
