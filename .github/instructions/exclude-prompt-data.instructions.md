---
description: "Write only the resulting content into files, with no prompt framing or meta-commentary"
applyTo: '**'
---

# Exclude Prompt Data

Write each file as if its content always belonged there. A reader with no
knowledge of the prompt should find it natural and self-contained.

- Describe the subject, not the change: "Validates email format", not
  "Added email validation as requested".
- Example data uses generic placeholders (`Jane Doe`, `jane.doe@example.com`,
  `Acme Corp`, `my-org`, `example.com`), never real names, emails, domains,
  enterprises or organizations from the prompt or local configuration.
- Output is polished and production-ready regardless of how the prompt was
  phrased.

Exceptions: verbatim text the user asks to insert, and prompt or instruction
files whose payload is instructions.
