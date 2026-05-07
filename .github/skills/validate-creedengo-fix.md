---
name: validate-creedengo-fix
description: Validate that a Creedengo fix is correct and doesn't introduce new violations
---

Validate the provided code fix for Creedengo compliance.

## Validation checklist:

1. **Fix correctness**: Does the fix actually resolve the reported GCI violation?
2. **No regression**: Does the fix introduce any NEW GCI violations?
3. **Behavior preservation**: Does the fix maintain the same functional behavior?
4. **Performance**: Is the fix at least as performant (or better) than the original?
5. **Best practice**: Is the fix the idiomatic/recommended solution for this rule?

## Specific validations per rule:

- **GCI1/GCI72 fix** (batch queries): Verify the batch actually reduces round-trips. Check SQL is correct.
- **GCI74 fix** (columns): Verify all needed columns are listed. No missing joins.
- **GCI75/GCI105 fix** (StringBuilder/join): Verify the result is identical.
- **GCI77 fix** (static Pattern): Verify thread-safety (static final is safe).
- **GCI79/GCI88 fix** (resources): Verify ALL resources in the scope are closed.
- **GCI82 fix** (final/const): Verify the variable truly isn't reassigned anywhere.
- **GCI84 fix** (async Task): Verify callers don't rely on fire-and-forget behavior.
- **GCI85 fix** (sealed): Verify no subclass exists anywhere in the codebase.
- **GCI94 fix** (orElseGet): Verify the lambda doesn't capture mutable state incorrectly.

## Output:

```
✅ VALID   — Fix correctly resolves GCI## without regression
⚠️ PARTIAL — Fix resolves GCI## but introduces: [issue]
❌ INVALID — Fix does not resolve GCI## because: [reason]
```

If invalid, provide the correct fix.

