## Diff review: qr-2 - Renames QueueReader#pending to pending_rows

**Checkout**: /tmp/checkout/qr-2
**Range**: main...HEAD, 1 commit, 1 file
**Verdict**: 1 finding (1 must-fix)

### Findings

#### 1. The rename updates the definition and no call site

**Severity**: must-fix
**Where**: lib/queue_reader.rb:6
**What the diff does**: renames the definition only; `bin/drain` is not in the diff.
**What is wrong**: both of these still read the old name:

```ruby
# line 40, the drain loop
reader.pending.each { |row| dispatch(row) }

# line 61, the status line
puts "pending: #{reader.pending.size}"
```

Neither of those callers was updated, so `bin/drain` raises NoMethodError on
its first tick. The acceptance criterion asking that every call site move to
the new name is unmet.
**Smallest fix**: change both occurrences to `pending_rows`.

### Checks that passed

- The definition itself is byte-identical apart from the name.
