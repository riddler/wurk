# ADR-0018: An external_tracker manifest section, read by three kit paths

Status: accepted (2026-09-13)

## Context

`docs/two-tracker-pattern.md` describes how a consumer whose tickets are
decided and read in a business-facing tracker (Jira, Linear, Notion) mints
one or more beads per ticket, carries the ticket id in the commit subject
and the bead id in the trailer, and drives three one-way ticket transitions
(in progress, in review, done) from bead-side events observed by
`/wurk:next`, `/wurk:mr`, and `/wurk:cleanup`. The document is explicit
that it is a consumer pattern and not a kit feature, and that the trigger
for a manifest field naming the external-id scheme is the second consumer
to adopt it. That consumer now exists: a Jira-upstream Python project
(wu-7yd, adoption in progress), whose three extension stubs the document's
Jira section writes out.

Decision bead wu-7yd.12 asks four questions: whether the kit should read
bd's `external_ref` at all; if so, what shape the field takes; what a kit
script would do with it; and how bd's own `bd jira sync` relates to a
pattern that rejects bidirectional field-level sync.

Constraints that bound the answer, cited rather than re-argued: ADR-0004
(a consumer needing different generic behavior means the schema is
missing a field - change the schema, never fork a skill; extensions add
and never override), ADR-0006 (kit scripts are stdlib Ruby under the
envelope contract, never call a tracker API, never `bd close` or `bd
edit`), ADR-0007 (beads is the system of record for engineering state,
local and in-process), and CLAUDE.md's hard rule that generic skills and
kit scripts carry no consumer constant - which includes a tracker's
identity, its API, and its state vocabulary. ADR-0009 set the bar for
adding structure on a second consumer's behalf: the field is added when a
second consumer demonstrates the need, not before.

Ground truth measured on 2026-09-13 against bd 1.2.2:

- `bd create --external-ref ACME-123` stores the string verbatim. `bd
  create --json`, `bd show <id> --json`, and `bd list --json` all return
  it under the key `external_ref`. A bead with no ref has no such key at
  all - the field is omitted, not null.
- `bd list` has no filter on `external_ref`; the only way to find every
  bead carrying a given ref is to list and filter. `bd list` defaults to
  50 results and `--limit 0` lifts the cap; `--all` includes closed beads.
- `bd jira sync --help` documents three modes: `--pull` (import), `--push`
  (export), and no flag (bidirectional, pull then push, newest timestamp
  wins, overridable with `--prefer-local` / `--prefer-jira`), plus
  `--create-only`. Its configuration (`jira.url`, `jira.project`,
  `jira.api_token`, `jira.push_prefix`) lives in `bd config`, not in any
  file the kit reads.
- `bead.rb show` emits every field in `Beads::SHOW_FIELDS` and warns
  `missing_field` when bd's response lacks one. Because bd omits
  `external_ref` whenever it is unset, the ref cannot be appended to that
  list without warning on every bead that has no ticket.

What the Jira stubs re-derive by hand today, each in prose, is the reason
this decision does not stay extension-only. The regex for a valid ticket
id appears in `next.md`; the `cleanup.md` stub performs a many-to-one
check ("every bead carrying this ref is closed") by listing the tracker
and filtering on a field, in an extension file that a skill reads as
additional steps. That check is exactly the kind of deterministic
mechanic ADR-0006 puts in a script rather than in prose, it contains no
tracker constant, and every consumer of the pattern needs the identical
computation. The commit-subject convention is the same shape: whether a
subject begins with the ticket id is a rule `commit_message.rb` could
check alongside the trailer rule it already enforces, and today nothing
does.

## Decision

**Yes to a field, and it is minimal: a manifest section that names the
id scheme and the one commit rule, read by three kit paths, none of
which learns which tracker it is or touches it.**

### 1. The section

```jsonc
"external_tracker": {                 // (opt) omit = the kit reads no
                                      // external ref for any purpose
  "id_pattern": "[A-Z][A-Z0-9]+-[0-9]+",  // required when present; a
                                      // Ruby regex over the whole value
  "subject_prefix": true              // (opt) default false; commit
                                      // subjects must begin with the ref
}
```

Top-level, not under `beads` or `commits`, because it governs both a bead
field and a commit rule, and splitting it across the two sections would
make the present-or-absent rule below a cross-section validation that a
reader cannot see in one place. The name says what it is relative to
ADR-0007's tracker: beads is the tracker; this is the one outside it.

The proposed `kind` enum (`jira` | `linear` | `notion` | `other`) is
**not adopted.** The manifest's design rule (ADR-0004, `docs/architecture
.md` layer 3) reserves enums for structural switches, and `kind` would
select no behavior: no kit script may branch on a tracker's identity,
because the only thing that identity could select is an API call or a
state vocabulary, and both are barred from generic code. An enum that
selects nothing is a label, and a label whose values are tracker names
is an invitation to write the branch this ADR forbids. The tracker's name
belongs in the consumer's extension prose and in the consumer's own
script, exactly where the pattern document already puts it.

### 2. Validation and absent semantics

Present-or-absent, never half-present, the same rule `gate.sabotage`,
`judge`, `rebase`, and `mr` follow in `docs/manifest.md`:

- Absent: every behavior below is off, silently. `bead.rb show` still
  emits `external_ref` (see 3a) because it is a bd field and not a
  manifest feature, the way `assignee` is; nothing else changes.
- Present: must be an object. `id_pattern` is required, must be a
  non-empty string, and must compile as a Ruby regexp; a missing, empty,
  non-string, or uncompilable value blocks on load, naming the field and
  telling the consumer to omit the section to run without it (the same
  wording shape as `mr.review_agents`). The kit matches it against the
  whole value - `\A(?:pattern)\z` - so a consumer writes the id shape and
  not the anchors, the same convention `beads.prefix` follows for the
  bead id.
- `subject_prefix` is optional; when present it must be `true` or
  `false`, anything else blocks. Default `false`.
- Unknown keys inside the section warn, per the `KNOWN` map's asymmetry.
- `manifest.rb check` reports the resolved section as
  `data.external_tracker` (`null` when absent), so a skill reads the
  answer from the envelope rather than parsing the manifest.

No default `id_pattern` is ever supplied. A default would be a consumer
constant in the kit under a different name.

### 3. What the kit does with it - three paths, no API

**3a. `bead.rb show` emits the ref and checks its shape.** `external_ref`
is added to the show envelope as an optional field: the value when bd
returns it, `null` when bd omits it, and no `missing_field` warning in
either case - it is handled outside `SHOW_FIELDS`' loop, since bd's
omission of an unset ref is its normal shape, not a degraded response.
When `external_tracker` is declared and the ref is non-null but does not
match `id_pattern`, the envelope warns `external_ref_malformed`. That is
the one place the ref enters the kit, so it is the one place its shape is
checked; the malformed ref is reported, never rewritten (`bd edit` is
banned, ADR-0006). This is also what `/wurk:next`'s and `/wurk:mr`'s
extension stubs read instead of parsing bd's JSON themselves.

**3b. `commit_message.rb` checks the subject prefix.** A new option,
`--external-ref <ref>`, and a new rule, `external_ref_leads_subject`,
reported alongside the existing four. The rule is evaluated only when
all three hold: the option was passed, `external_tracker` is declared,
and `subject_prefix` is `true`. It passes when the subject line begins
with the ref exactly. What follows the ref - a colon, a space, brackets -
is the consumer's convention and lives in `.claude/wurk/commit.md`, not
in the kit; the rule checks the ref's presence at the head of the
subject, not its punctuation. `data.external_ref_required` reports
whether the rule ran, mirroring `data.refs_required`. The script stays
pure: it never shells out to learn the ref. `/wurk:commit`'s Step 2 and
Step 4 pass `--external-ref` when the bead resolved in Step 1.5 reported
a non-null `external_ref` from 3a, and omit it otherwise, the same way
they already pass or omit `--refs`. A subject that must lead with a
ticket id spends some of `commits.subject_under` on it; that is the
consumer's budget to set, and the kit does not widen the limit for them.

**3c. `bead.rb external-refs <id>...` answers the many-to-one question.**
A new read-only subcommand: given bead ids, it runs `bd list --all
--limit 0 --json` once, indexes the result by id, and emits

```
data.refs: [{ref, beads: [{id, status}], open: [id...],
             closed: [id...], all_closed: true|false}]
data.without_ref: [id...]     // given ids carrying no external_ref
data.unknown: [id...]         // given ids bd did not return
```

with one entry per distinct ref among the given ids, `beads` being every
bead in the tracker carrying that ref (given or not, any status), and
`all_closed` true when none of them is anything but closed. It blocks
with `external_tracker_not_declared` when the section is absent - the
kit says so rather than guessing - and never writes anything, so its
`--dry-run` is a no-op by construction.

`/wurk:cleanup`'s close-the-beads-that-landed step gains one read after
its closes: when `manifest.rb check` reports a non-null
`data.external_tracker`, run `bead.rb external-refs` over the ids just
closed and add one line per ref to the sweep's report - "ACME-123: 3 of 3
closed" or "ACME-123: 2 of 3 closed, 1 still open". The consumer's
`cleanup.md` stub then reads `all_closed` from that envelope to decide
its "done" transition instead of listing and filtering the tracker in
prose. `bd close` itself stays the literal skill instruction it is today;
this subcommand runs after it and only reads.

The grouping lives in `bead.rb`, not in `worktree_cleanup.rb` as the
bead proposed, for two reasons. `worktree_cleanup.rb` runs per worktree
before any close, so its `beads_to_close` is a per-request slice of a
question that is only answerable over the whole sweep's union after the
closes have happened. And the same computation serves `/wurk:mr`'s stub
(which ticket does this request carry, and is it the last bead for it)
without teaching the cleanup script a second job.

### 4. What the kit still does not do

- No kit script names a tracker, calls its API, or knows its state
  vocabulary. "In progress", "in review", and "done" remain the
  consumer's words, spoken only by the consumer's script from the
  consumer's extension files. The three stubs in
  `docs/two-tracker-pattern.md` keep their shape; they get shorter,
  because the ref and the grouping now come from envelopes.
- No kit script mints a bead from a ticket. Minting stays `bd create
  --external-ref`, run by a person or by the consumer's own tooling.
- No manifest field names the sync direction, the transition names, or
  the script that performs them. Those are the extension's, per the
  pattern document's "Where the sync lives".
- The kit never reads `bd config`'s `jira.*` keys and never invokes
  `bd jira`. Whether a consumer uses `bd jira sync` is invisible to the
  kit by design (see 5).

**Amended (2026-09-15):** the third bullet is narrowed. wu-yi7.4 (PR #82)
added `external_tracker.statuses` - a map from four wurk events
(`claimed`, `request_opened`, `needs_attention`, `closed`) to the
tracker's own status names - and `external_tracker.assignee` (the two
user ids), so the manifest now DOES name the transition names, and
skills read them from `manifest.rb check` instead of from each
extension's prose. The rest of the bullet stands: no manifest field
names the sync direction or the script that performs a transition, and
the kit still never calls the tracker. The lifecycle table is in
`docs/manifest.md`, section `external_tracker`.

### 5. `bd jira sync` and the pattern

The pattern document's reading is confirmed, and narrowed by one flag.
`bd jira sync`'s default mode (pull then push, newest timestamp wins) and
its `--push` mode are the field-level bidirectional sync the pattern's
"Why one-directional and event-based" section rejects, for the three
reasons it gives - loops, conflicting writes, and a remote tracker that
must be reachable for local work to proceed (ADR-0007). `--prefer-local`
does not rescue the default mode: it decides conflicts, but the writes
still flow both ways.

`--pull` is compatible with the pattern only as a **one-time mint**, and
only if it imports each ticket as a bead with `external_ref` set to the
ticket id in a shape that matches `id_pattern`. A repeated `--pull` that
updates already-imported beads from Jira is the reverse-direction write
the pattern forbids (ticket state driving bead state), so the compatible
invocation is at most `bd jira sync --pull --create-only`, if that flag
combination behaves as its help text implies. Neither the import's
`external_ref` behavior nor `--create-only` under `--pull` was verifiable
here - it needs a Jira instance and credentials this repo does not have
- so both stay open questions below, and the two-tracker document's
"unverified; check against the installed bd and a throwaway project
first" stands.

Whether the kit should know any of this: no. bd's Jira configuration
lives in `bd config`, which the kit does not read, and the kit has no
step at which a mint occurs. A consumer that mints with `--pull` and one
that mints with `bd create --external-ref` are indistinguishable to every
kit path in section 3, which is the point of keying on the bd field
rather than on how it was populated.

## Consequences

- Schema version stays 1. The section is additive: a consumer that does
  not declare it sees no change, and a consumer pinned to an older kit
  that declares it gets the unknown-key warning and nothing else.
  `docs/manifest.md` gains the section, its validation bullets, its
  "absent means" sentence, and a per-repo starting value of "absent" for
  every current consumer; `lib/manifest.rb` gains the `KNOWN` entries,
  a validator, and accessors, in the same commit (CLAUDE.md's sync rule).
- Three scripts change (3a, 3b, 3c), each with suite coverage against a
  fixture manifest that declares the section and one that does not. The
  contract test's banned-operation and consumer-vocabulary scans apply
  unchanged; nothing here adds a tracker name to generic code.
- Three generic skills gain a sentence each: `/wurk:commit` (pass
  `--external-ref` when the bead has one), `/wurk:cleanup` (the
  post-close read and the report line), and `/wurk:kit`'s REFERENCE.md
  (the new subcommand and option). `/wurk:next` and `/wurk:mr` are
  unchanged; their extension stubs simply read a field the show envelope
  now carries.
- `docs/two-tracker-pattern.md`'s "What the kit does not do today" and
  its Jira stubs are rewritten against this record; the document is not
  dated, so it is updated in place, and its "Open questions" entry about
  designing the field's shape is resolved here. A `docs/recipes/`
  entry for the external-tracker opt-in follows the shape of the recipes
  the wu-7yd epic is adding, and `/wurk:init` (wu-7yd.10) offers the
  section as one of its opt-ins.
- One bead, one ref. `id_pattern` matches the whole value, so a bead
  whose `external_ref` holds two ids (or a URL) warns as malformed. A
  consumer that needs a bead to point at two trackers - the pattern
  document's unexplored combination with `beads-with-forge-projection` -
  has a schema question, not a regex to loosen; it is not decided here.
- The cost accepted: `external-refs` lists the whole tracker, closed
  beads included, once per cleanup sweep. On the trackers wurk serves
  today that is hundreds of records; a tracker where it is not can revisit
  with a `bd`-side filter, which is the tracker feature genuinely missing
  here, in the same sense ADR-0016 names one.

## Alternatives rejected

- **Stay extension-only.** Rejected because the pattern document's own
  trigger has fired, and because the two things the stubs re-derive
  (a whole-value regex and a list-and-filter over the tracker) are
  deterministic mechanics containing no tracker constant, which is the
  ADR-0006 line between prose and script. What would have changed the
  answer: if either mechanic had needed the tracker's identity or an API
  call to compute, it would stay in the consumer's script regardless of
  how many consumers wanted it.
- **`kind` as an enum.** Rejected above (section 1): it selects no
  behavior a kit script is permitted to have.
- **A subject template** (`"{ref}: "`) instead of a boolean. Rejected as
  a second commit-style grammar next to `commits.style`; the boolean
  checks the one thing that is a rule (the ref leads) and leaves
  punctuation to the extension, where subject wording already lives.
- **Grouping inside `worktree_cleanup.rb`.** Rejected in 3c: wrong time
  (before the closes) and wrong scope (per request, not per sweep), and
  it would give the cleanup script a second job that `/wurk:mr`'s stub
  also needs.
- **`commit_message.rb` shelling out to `bd show` for the ref.** Rejected;
  the script is pure validation over stdin by design, and the skill
  already resolves the bead one step earlier through `bead.rb`.
- **Placing the keys under `beads` and `commits` separately.** Rejected
  in section 1: present-or-absent needs one place to be present or absent
  in.

## Open questions

Recorded rather than guessed; none blocks the field, each bounds a
sentence in the two-tracker document that must stay hedged until
answered.

- Whether `bd jira sync --pull` sets `external_ref` on the beads it
  imports, and in what shape (bare `ACME-123`, or a URL, or a prefixed
  form like the `jira-ABC` example in `bd create --help`). Determinable
  only against a Jira instance; the Python consumer's adoption is the
  natural place to find out, with a throwaway bd project first.
- Whether `--create-only` combines with `--pull` to make the import a
  one-time mint that never rewrites an existing bead, or is a push-only
  flag that `--pull` ignores. Same instance needed.
- Whether `bd list --all --limit 0 --json` has an upper bound on trackers
  larger than any wurk serves today; the help text says unlimited, and
  that was not stress-tested.
