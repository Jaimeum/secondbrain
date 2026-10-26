---
description: File a useful chat answer back into the wiki as a question page
argument-hint: '{"project": "<slug|null>", "question": "...", "answer": "..."}'
---

# Save an answer into the wiki

Arguments (JSON): `$ARGUMENTS`

The owner asked a question in the app's chat and chose "Guardar en el wiki / Save to wiki". File
the answer so the knowledge compounds. Follow `CLAUDE.md` at the vault root (naming, language,
citations, links). Never ask questions.

## Steps

1. Parse the JSON: `project` (slug or null), `question`, `answer`. The answer already contains
   citations as wikilinks; keep them.
2. Choose the destination:
   - `project` is a slug → `projects/<slug>/wiki/questions/`.
   - `project` is null → if every wiki citation in the answer belongs to one project, use that
     project; otherwise use the global `questions/` folder at the vault root.
3. Read the project `wiki/index.md` (or global `index.md`). If a question page on the same
   subject already exists, update it (new "Respuesta" content, `updated:`, sources) instead of
   creating another.
4. Verify the answer against the wiki: Read the pages it cites. Remove or fix any citation whose
   target doesn't exist. If a statement in the answer is not supported by the cited pages, keep it
   only if it is clearly labelled as inference; never add new facts of your own.
5. Write `questions/YYYY-MM-DD-<slug>.md` (today's date; slug = short kebab-case of the question)
   using the question template in CLAUDE.md §8.6 with `status: answered`, `origin: chat`,
   `language` = the question's language, `sources:` = the raw files behind the cited pages.
   Body: `# <question>` · `## Respuesta` (the answer as given, in its own language, only cleaned of
   chat phrasing such as "Claro," or offers to help; citations kept; do not translate or reword it) · `## Fuentes` (bullets linking the wiki pages used).
6. Link it:
   - add a line under "Preguntas" in the project `wiki/index.md` (or under "## Preguntas
     guardadas" in the global `index.md`);
   - add a "Relacionado" / "Preguntas" link from the 1-3 most relevant topic or decision pages;
   - if it answers an open question listed in `overview.md` or an open question page, mark that
     one answered and link the new page.
7. Append to the project `wiki/log.md` (or only `log.md` for global) and to `log.md`:
   `## [today] answer | <question>` + 1 bullet pointing to the new page.

## Final message

Exactly one short line in the question's language, no file paths, no list of changes, e.g.
"Guardé la respuesta en el wiki de X-Files como «¿Quién aprueba el presupuesto de Q1?»."
