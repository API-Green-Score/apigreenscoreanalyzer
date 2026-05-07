Scan the code for **Creedengo eco-design** violations (official GCI rules) and fix them.

## What to look for:

### Java
- **GCI1**: Spring repository in loop/stream → batch/JOIN
- **GCI3**: Collection.size() in loop condition → cache size
- **GCI5**: Statement vs PreparedStatement
- **GCI69**: Loop-invariant function in condition → extract
- **GCI72**: SQL query in loop → batch
- **GCI74**: SELECT * → specify columns
- **GCI77**: Pattern.compile() non-static → static final
- **GCI79**: Unclosed resources → try-with-resources
- **GCI82**: Variable never reassigned → final
- **GCI94**: orElse() with computation → orElseGet()

### C# / .NET
- **GCI72**: EF/SQL query in loop → batch
- **GCI75**: String concat in loop → StringBuilder
- **GCI83**: Enum.ToString() → nameof()
- **GCI84**: async void → async Task
- **GCI85**: Unsealed type → sealed
- **GCI86**: GC.Collect() → remove
- **GCI87**: LINQ First()/Last() → indexer
- **GCI88**: IAsyncDisposable → await using
- **GCI91**: Sort before filter → filter first
- **GCI92**: Compare to "" → IsNullOrEmpty
- **GCI93**: Single await → return Task directly

### Python
- **GCI72**: SQL in loop → executemany
- **GCI74**: SELECT * → columns
- **GCI89**: lru_cache without maxsize → add maxsize
- **GCI103**: .items() when only key/value → .keys()/.values()
- **GCI105**: String += in loop → join()
- **GCI109**: Exception for control flow → dict.get()
- **GCI110**: from x import * → explicit imports
- **GCI111**: f-string in logging → %s
- **GCI112**: Dataclass → add slots=True
- **GCI404**: List comprehension in for → generator

## Output format:

For each violation:
```
📍 [GCI##] File:Line — Description
   Before: <problematic code>
   After:  <fixed code>
```

At the end, estimate the **Creedengo Score** (100 minus 3 pts per issue).
