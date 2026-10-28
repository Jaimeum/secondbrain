---
description: Decide which ambiguous email attachments are worth keeping (read-only, JSON output)
argument-hint: <JSON {"email": "<vault-relative raw email path>", "attachments": [{"name", "path", "mime", "size"}]}>
---

# Triage email attachments

Arguments: `$ARGUMENTS`

<!-- v0.7 (CONTRACT §17.1): placeholder from the foundation; filled in by the attachments work. -->

**Read-only**: do not create or edit any file. Do not ask questions.

Read the email and each attachment listed (images with Read). Answer ONLY with a JSON array, one item per
attachment, in the same order:

```json
[{"name": "contrato.pdf", "keep": true, "reason": "Contrato firmado del proyecto"}]
```
