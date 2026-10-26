---
description: Suggest which project an unassigned source belongs to (read-only, JSON output)
argument-hint: <vault-relative path to a file in _inbox>
---

# Classify an unassigned source

Source: `$ARGUMENTS`

Decide which existing project this source belongs to. **Read-only**: do not create or edit any
file. Do not ask questions.

## Steps

1. Glob `projects/*/project.json` and Read each one (name, description). If there are no
   projects, answer with `"project": null`.
2. Read `index.md` (global) and each project's `projects/<slug>/wiki/overview.md` (skim: En breve,
   Objetivo, Personas, Glosario). For many projects, Read the overviews of the most plausible
   ones only.
3. Read the source. For a long transcript, the first ~150 lines plus a Grep for project names,
   people names, clients and glossary terms are enough.
4. Compare: explicit project or client names, people who belong to a project, glossary terms,
   subject matter. Names of people and project-specific terms are strong evidence; a generic
   subject ("budget", "planning") is weak.
5. Confidence: `0.9+` explicit project/client name or several project-specific terms; `0.6-0.8`
   strong overlap of people and subject; `0.3-0.5` weak thematic match; below `0.3` → use
   `null`. Never force a match.

## Output

Your entire final message must be exactly ONE line of minified JSON and nothing else — no code
fence, no text before or after:

{"project":"<slug or null>","confidence":<0-1 number>,"reason":"<one short sentence in the source's language, for a non-technical user>"}

`project` is a slug that exists (folder name under `projects/`) or JSON `null` (not the string
"null"). Example:

{"project":"xfiles","confidence":0.85,"reason":"Se habla del lanzamiento de X-Files con Ana y Luis, que participan en ese proyecto."}
