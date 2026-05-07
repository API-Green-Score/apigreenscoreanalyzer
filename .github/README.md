# Green API Copilot Agents & Tools

This folder contains GitHub Copilot customizations to make your code **Green API** and **Creedengo** compliant.

## Structure

```
.github/
├── copilot-instructions.md          # Global Copilot instructions (applied to all chats)
├── agents/
│   ├── global-green-analyzer.md     # Agent: Combined Green API + Creedengo analysis
│   ├── green-api-analyzer.md        # Agent: Green API Score analysis & fixes
│   ├── creedengo-analyzer.md        # Agent: Creedengo eco-design static analysis
│   └── api-design-reviewer.md       # Agent: OpenAPI spec & design review
├── skills/
│   ├── green-api-score.md           # Skill: Calculate Green API Score
│   ├── green-api-fix.md             # Skill: Apply Green API fixes to code
│   ├── validate-green-api-fix.md    # Skill: Validate a Green API fix is correct
│   ├── creedengo-scan.md            # Skill: Scan for Creedengo violations
│   ├── validate-creedengo-fix.md    # Skill: Validate a Creedengo fix is correct
│   ├── add-pagination.md            # Skill: Add DE11 pagination
│   ├── add-etag-304.md              # Skill: Add DE02/DE03 ETag + 304
│   ├── add-field-filtering.md       # Skill: Add DE08 fields param
│   ├── add-compression.md           # Skill: Add DE01 gzip/brotli
│   ├── add-delta-endpoint.md        # Skill: Add DE06 /changes?since=
│   ├── add-rate-limiting.md         # Skill: Add US07 rate limiting
│   └── add-health-endpoint.md       # Skill: Add LO01 health check
├── prompts/
│   ├── green-api-review.md          # Prompt: Review code for Green API + Creedengo
│   ├── green-api-fix.md             # Prompt: Fix Green API violations
│   ├── creedengo-fix.md             # Prompt: Fix Creedengo violations
│   ├── generate-green-endpoint.md   # Prompt: Generate a green-compliant endpoint
│   └── optimize-query.md            # Prompt: Optimize DB queries for eco-design
└── README.md                        # This file
```

## How to use

### In VS Code / JetBrains with Copilot Chat

1. **Global instructions** (`copilot-instructions.md`) are automatically applied to all Copilot interactions in this workspace.

2. **Agents** can be invoked with `@workspace` or referenced in custom chat participants:
   - Ask: _"Review this controller for Green API compliance"_
   - Ask: _"What Creedengo violations do you see in this file?"_
   - Ask: _"Generate a GET /books endpoint that scores 100/100"_

3. **Prompts** are reusable prompt files you can invoke from the command palette or chat.

## Quick Examples

### Green API Review
```
@workspace Review my BookController for Green API Score. Check DE11, DE08, DE01, DE02.
```

### Creedengo Fix
```
@workspace Find Creedengo eco-design violations in src/main/java and fix them.
```

### Generate Green Endpoint
```
@workspace Generate a GET /api/products collection endpoint with full Green API compliance (pagination, fields, gzip, ETag, delta).
```
