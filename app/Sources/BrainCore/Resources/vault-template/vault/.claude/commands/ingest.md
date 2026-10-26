---
description: Learn from one raw source and integrate it into the project wiki
argument-hint: <vault-relative path to a raw file>
---

# Ingest a source into the wiki

Source to ingest: `$ARGUMENTS`

You are the wiki maintainer described in `CLAUDE.md` at the vault root (your working directory).
Follow it strictly: its rules on naming, language, citations, speakers, conflicts and "Never"
apply to everything below. You run unattended: never ask questions, never stop halfway.

## 1. Orient

1. If `CLAUDE.md` (vault root) is not already in your context, Read it.
2. From the path, get:
   - the project slug: the segment after `projects/` (if the path is not under
     `projects/<slug>/raw/`, stop and reply with one line explaining that the source must be
     assigned to a project first);
   - the **source key**: the filename without extension;
   - the kind: `raw/meetings/` → meeting, `raw/docs/` → document, `raw/notes/` → note (a note or
     doc with `source_url` in its frontmatter is a url source).
3. Read, in this order: `projects/<slug>/CLAUDE.md`, `projects/<slug>/project.json` (if it
   exists), `projects/<slug>/wiki/index.md`, `projects/<slug>/wiki/overview.md`,
   `projects/<slug>/wiki/tasks.md`, `people/README.md`. Glob `people/*.md` to know which people
   pages exist.
4. Grep `projects/<slug>/wiki/log.md` for the source key. If it was already ingested, this is a
   **re-ingest**: update the existing pages in place (no duplicates) and say so in the log.

## 2. Read the source completely

Read the whole file. If the Read result is truncated, keep reading with `offset` until the end —
never summarize a source you only partly read. PDFs and images: Read them directly.
For a transcript, note the meeting date from `date:` (use it to resolve relative dates like
"el viernes", "next week") and the speaker labels.

## 3. Analyze before writing

Work out (internally, don't output it):
- What this source is about, in 2-3 sentences, and what it changes for the project.
- **Speakers** (meetings): apply CLAUDE.md §7 strictly. For each label: person or null,
  confidence, evidence with timestamp. Check existing people pages and aliases first. Detect
  whether the owner ("Yo"/"Me") is named.
- **People** mentioned or speaking, with work-relevant facts (role, org, expertise, opinions on
  project matters).
- **Decisions** (real ones only), **tasks** (owner, due date resolved to YYYY-MM-DD, citation),
  **open questions**, **risks**, important **numbers and dates**, **milestones**.
- **Topics**: which existing topic pages this feeds; which new subjects deserve a page
  (CLAUDE.md §8.3).
- **Conflicts**: compare every important fact with what the wiki already says (overview, tasks,
  topic and decision pages). Classify each difference as explicit change vs. unresolved conflict
  (CLAUDE.md §9).
- **Glossary / spelling**: new project terms, acronyms, recurring misheard words.
- The language of the source (dominant language, ignoring borrowed jargon).

## 4. Write the source page

Create (or, on re-ingest, update) the source page using the exact template in CLAUDE.md:
- meeting → `projects/<slug>/wiki/meetings/<source key>.md` (§8.1)
- document / note / url → `projects/<slug>/wiki/sources/<source key>.md` (§8.2)

Every claim is cited — on its own page a meeting cites just the `(HH:MM:SS)` timestamp (CLAUDE.md §5). Include the
`speakers:` mapping for every label. End with the link to the raw file.

## 5. Update the rest of the wiki (typically 5-15 pages)

Before creating any page, check it doesn't exist under another name (index, Glob, Grep by
aliases). Read an existing page before editing it; edit surgically with Edit/MultiEdit.

1. **People** (`people/`): create or update the page of every relevant person: role, projects,
   facts with citations, "En reuniones" line with their label for this meeting, and their open
   commitments. Add new aliases you saw. If the owner was identified, update `people/README.md`
   and create/update their page with `owner: true`.
2. **Decisions**: one page per new decision (§8.4); update status/Historial of existing
   decisions this source confirms, changes or reverses.
3. **Topics**: update existing topic pages (En breve, Estado actual, Historia with dated bullets);
   create new ones only when justified. Cross-link topics, decisions, people and the meeting.
4. **Questions**: add open questions to the meeting page and to the overview; create a question
   page only for important recurring/blocking questions; if this source answers an existing
   open question, update it to `answered`.
5. **`wiki/tasks.md`**: add new tasks in the exact checkbox format, under the right owner group;
   mark tasks done (`[x]` + `✅ date`) when this source says so; update changed deadlines keeping
   the previous one visible. No duplicates.
6. **`wiki/overview.md`**: rewrite the affected sections so it reads as the current state of the
   project (En breve, Objetivo if learned, Estado actual, Decisiones clave, Próximos hitos,
   Riesgos, Preguntas abiertas, Personas, Línea de tiempo, Glosario). On the project's first
   ingest, replace the seed placeholders entirely. Apply the navigation language rule (§4).
7. **Conflicts**: put `> [!conflict]` callouts (or `> [!note] Cambio` for explicit changes) on
   every page where the affected fact lives — at least the topic/decision page and the overview.
8. **`projects/<slug>/CLAUDE.md`**: add recurring misheard words to "Correcciones de
   transcripción" and new topic pages to "Temas principales". Glossary terms go in the overview,
   not here. Don't touch the owner's sections (Objetivo, Reglas del proyecto).
9. **`projects/<slug>/wiki/index.md`**: add a line for every page you created, in the right
   section; refresh one-line summaries of pages whose meaning changed; update `updated:`.
10. **`index.md`** (global): add a line under `## Personas` for each new person page; keep
    existing lines (update the role/projects part if it changed).
11. **Logs**: append one entry at the bottom of `projects/<slug>/wiki/log.md` and one at the
    bottom of `log.md`, exactly as in CLAUDE.md §8.7 (`## [today] ingest | <title>`, 1-3 bullets;
    global title ends with ` (<slug>)`).

## 6. Check your work

- Glob/Grep the pages you wrote: every `[[link]]` target must exist as a file (bare names
  anywhere in the vault; path links at that path). Fix or unlink any that don't.
- Every page you created or changed has valid frontmatter, `updated:` = today, and the raw path
  in `sources:`.
- No claim without a citation; no invented timestamps; no secrets copied.
- New pages appear in the project `index.md`.

## 7. Final message

Your final message is shown to a non-technical user in the app as "what I learned". Write it in
the language of the source and address the owner ("Yo"/"Me") in the second person: "Tú escribes
las release notes…" / "You'll compare…", never "Yo escribo…" / "I'm to…". The message must start
directly with the first bullet — no status sentence before it. Output ONLY 3-6 bullet lines (`- `), no heading, no preamble, no
nested bullets, no bold, no file paths, no wikilink syntax, no jargon (vault, raw, frontmatter,
wiki maintainer) — plain human sentences of at most ~25 words each. Dates as people say them
("3 de noviembre", "November 3"). Cover: the gist of the source,
the most important decisions/commitments (with owner and date), people identified (say who
"Hablante N" turned out to be, or that a speaker couldn't be identified), conflicts or changes
detected, and which wiki pages were created or updated (by title). Example:

- Reunión de arranque de X-Files con Acme: se acordó lanzar el 15 de noviembre.
- 4 pendientes nuevos; el más urgente: Ana envía la propuesta revisada antes del 3 de noviembre. Tú preparas la demo.
- Identifiqué a Hablante 1 como Ana García (se presentó); Hablante 2 no se pudo identificar.
- ⚠️ La fecha de lanzamiento contradice la nota anterior (22 de noviembre); lo marqué para revisar.
- Páginas nuevas: Plan de lanzamiento, Ana García, 2 decisiones. Actualicé el resumen y los pendientes.
