---
description: File a useful chat answer back into the wiki as a question page, in the scope it was asked in
argument-hint: '{"scope": "brain|project", "project": "<slug|null>", "question": "...", "answer": "...", "path": "<page|null>"}'
---

# Save an answer into the wiki

Arguments (JSON): `$ARGUMENTS`

The owner asked a question in the app's Preguntar (or a meeting's preparation) and chose
"Guardar como página / Save as page". File the answer so the knowledge compounds. Follow
`CLAUDE.md` at the vault root (naming, language, citations, links) and never contradict
`facts.md`. Never ask questions.

## Steps

1. Parse the JSON: `scope` (`"brain"` or `"project"`), `project` (slug or null), `question`,
   `answer`, `path` (the page the app already wrote, or null). The answer already contains
   citations as wikilinks; keep them.
2. The destination is fixed by `scope`, never by the citations:
   - `scope` = `"project"` → `projects/<project>/wiki/questions/`, linked from that project's
     `wiki/index.md` and `wiki/log.md`;
   - `scope` = `"brain"` → the global `questions/` folder at the vault root, linked from the global
     `index.md` and `log.md`.
   Never move the page to, or create it in, another scope (another project, or global ↔ project),
   even when every citation belongs to one project.
3. The page:
   - `path` is given → the app already wrote it there. Do not create another page, do not rename
     or move it. You may only clean it (step 4) and fill `sources:`.
   - `path` is null → write `<folder>/YYYY-MM-DD-<slug>.md` (today's date; slug = short kebab-case
     of the question) using the question template in CLAUDE.md §8.6 with `status: answered`,
     `origin: chat`, `language` = the question's language, `sources:` = the raw files behind the
     cited pages. Body: `# <question>` · `## Respuesta` (the answer as given, in its own language,
     only cleaned of chat phrasing such as "Claro," or offers to help; citations kept; do not
     translate or reword it) · `## Fuentes` (bullets linking the wiki pages used). If a question
     page on the same subject already exists in the same folder, update it instead (new
     "Respuesta" content, `updated:`, sources).
4. Verify the answer against the wiki: Read the pages it cites. Remove or fix any citation whose
   target doesn't exist. If a statement is not supported by the cited pages, keep it only if it is
   clearly labelled as inference; never add new facts of your own.
5. Link it (in the destination's scope only):
   - add a line under "Preguntas" in the project `wiki/index.md` (or under "## Preguntas
     guardadas" in the global `index.md`);
   - add a "Relacionado" / "Preguntas" link from the 1-3 most relevant topic, decision, person or
     org pages;
   - if it answers an open question listed in `overview.md` or an open question page, mark that
     one answered and link the new page.
6. Append to the project `wiki/log.md` (project scope) and to the global `log.md`:
   `## [today] answer | <question>` + 1 bullet pointing to the page.

## Final message

Exactly one short line in the question's language, no file paths, no list of changes, e.g.
"Guardé la respuesta en el wiki de X-Files como «¿Quién aprueba el presupuesto de Q1?»."
