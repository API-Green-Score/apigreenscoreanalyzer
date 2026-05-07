Optimize the following database query/repository code for **eco-design** (Creedengo GCI + Green API).

## Check for these Creedengo violations:

1. **GCI74 — SELECT ***: Replace with explicit column list
2. **GCI1/GCI72 — N+1 / SQL in loop**: Replace loop+query with JOIN, IN clause, or batch fetch
3. **GCI95 — Unused queried columns**: Only fetch columns that are actually used downstream
4. **DE08 — Over-fetching**: Support `fields` param to only fetch needed columns
5. **DE11 — No pagination**: Add `LIMIT`/`OFFSET` or framework equivalent
6. **GCI79/GCI88 — Connection leaks**: Ensure connections are closed (try-with-resources / await using)
7. **GCI5 — Statement vs PreparedStatement** (Java): Use PreparedStatement

## Additional optimizations:
- **Indexing**: Suggest indexes for WHERE/ORDER BY columns
- **Eager loading**: Replace `FetchType.EAGER` with `LAZY` + explicit fetch when needed (CRJVM205)
- **GCI78**: Don't set const parameters in batch update — put in query
- **GCI32**: Initialize StringBuilder with capacity

## Output:

For each optimization:
```
🔧 [GCI##] Issue: <description>
   Impact: <estimated resource savings>
   Before: <code>
   After:  <code>
```

Also suggest:
- Caching strategy (Redis, in-memory, HTTP cache headers)
- Batch sizes for bulk operations
- Connection pool sizing recommendations
