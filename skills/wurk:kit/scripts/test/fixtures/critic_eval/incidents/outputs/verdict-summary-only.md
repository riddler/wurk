## Diff review: qr-1 - Adds QueueReader#claimed

**Checkout**: /tmp/checkout/qr-1
**Range**: main...HEAD, 1 commit, 1 file
**Verdict**: 2 findings (0 must-fix)

### Findings

#### 1. The new predicate has no test in this diff

**Severity**: should-fix
**Where**: lib/queue_reader.rb:8
**What the diff does**: adds `claimed`, a select over the rows.
**What is wrong**: nothing would go red if the filter were inverted.
**Smallest fix**: one test over a two-row fixture.

#### 2. The comment restates the method name

**Severity**: note
**Where**: lib/queue_reader.rb:7
**What the diff does**: adds a one-line comment above the method.
**What is wrong**: it says what the name already says.
**Smallest fix**: drop it, or say why "claimed" excludes "offered".

### Checks that passed

- Scope: one additive method, nothing else touched.
- Contracts: no existing caller changed.
