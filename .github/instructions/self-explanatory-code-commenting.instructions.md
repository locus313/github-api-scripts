---
description: 'Comment only to explain why: API constraints, gotchas, regexes and non-obvious logic'
applyTo: '**'
---

# Code Comments

Prefer clear names over comments. Write a comment when it explains **why**:

- API constraints and gotchas (rate limits, sentinel return values, endpoints
  that ignore a query parameter)
- What a regex or jq filter matches
- Non-obvious business logic or algorithm choices

Delete commented-out code and history notes; git keeps both.
