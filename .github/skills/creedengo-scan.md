---
name: creedengo-scan
description: Scan code for Creedengo eco-design violations (official GCI rules) and provide fixes
---

Scan the provided code for official Creedengo (Green Code Initiative) eco-design anti-patterns.

## Java detection rules:

- **GCI1**: Spring repository call inside loop/stream → batch query or JOIN
- **GCI2**: Multiple if-else on same variable → use switch
- **GCI3**: Collection.size() in loop condition → cache before loop
- **GCI5**: Statement instead of PreparedStatement → use PreparedStatement
- **GCI27**: Manual array copy → System.arraycopy()
- **GCI32**: StringBuilder without initial capacity → specify size
- **GCI67**: Post-increment `i++` in for loop → `++i`
- **GCI69**: Loop-invariant function call in condition → extract variable
- **GCI72**: SQL query inside loop → batch queries
- **GCI74**: SELECT * FROM → specify columns
- **GCI76**: Non-final static collections → make final
- **GCI77**: Pattern.compile() in non-static context → static final
- **GCI79**: Resources not freed → try-with-resources
- **GCI82**: Variable never reassigned → make final
- **GCI94**: orElse() with computation → orElseGet()

## C# detection rules:

- **GCI69**: Loop-invariant call in condition → cache
- **GCI72**: SQL/EF query inside loop → batch
- **GCI75**: String concat in loop → StringBuilder
- **GCI81**: Struct without layout → [StructLayout]
- **GCI82**: Variable never reassigned → const/readonly
- **GCI83**: Enum.ToString() → nameof()
- **GCI84**: async void → async Task
- **GCI85**: Unsealed type → sealed
- **GCI86**: GC.Collect() → remove
- **GCI87**: LINQ First()/Last() → indexer
- **GCI88**: IAsyncDisposable not async disposed → await using
- **GCI91**: Sort before filter → filter first
- **GCI92**: Compare to "" → string.IsNullOrEmpty
- **GCI93**: Single await → return Task directly

## Python detection rules:

- **GCI2**: Multiple if-else → match/dict dispatch
- **GCI4**: Global variables → function arguments
- **GCI35**: try/catch for file check → os.path.exists()
- **GCI72**: SQL in loop → executemany
- **GCI74**: SELECT * → specify columns
- **GCI89**: lru_cache without maxsize → add maxsize
- **GCI96**: Read all CSV columns → usecols=
- **GCI103**: .items() when only key/value needed → .keys()/.values()
- **GCI105**: String += in loop → join()
- **GCI109**: Exception for control flow → dict.get()
- **GCI110**: from x import * → explicit imports
- **GCI111**: f-string in logging → %s lazy format
- **GCI112**: Dataclass without slots → slots=True
- **GCI404**: List comprehension in for → generator

## Output format:

```
📍 [GCI##] file:line — description
   ❌ Before: <code>
   ✅ After:  <fixed code>
```

Final score: 100 − (3 pts per issue)
Grade: A (≥90) | B (≥80) | C (≥70) | D (≥50) | E (<50)
