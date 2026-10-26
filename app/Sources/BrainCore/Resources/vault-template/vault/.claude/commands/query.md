---
description: Answer a question from the wiki, with citations (read-only)
argument-hint: scope=<project-slug|global> | <question>
---

# Answer a question from the wiki

Request: `$ARGUMENTS`

The request has the form `scope=<slug|global> | <question>`. You are answering the owner of this
vault (a non-technical person) inside the SecondBrain app, using ONLY what the wiki and its raw
sources say. `CLAUDE.md` at the vault root describes how the wiki is organized.

**Read-only.** Do not create, edit or delete any file. Never ask follow-up questions: answer with
what you have.

## Steps

1. Parse the scope and the question. If the scope is missing or unknown, treat it as `global`.
2. Start from the index:
   - scope = a project slug → Read `projects/<slug>/wiki/index.md`, then
     `projects/<slug>/wiki/overview.md`.
   - scope = `global` → Read `index.md`, then the `wiki/index.md` of the projects that look
     relevant (if unsure, of all projects).
3. Open the pages the index points to (topics, decisions, meetings, people, `tasks.md`). Grep the
   wiki for names, terms and synonyms in both Spanish and English when the index isn't enough.
   For people questions, read `people/<name>.md`.
4. Go to the raw source (transcript, document) only when you need an exact detail the wiki page
   lacks (an exact quote, a number, who said what). Use the timestamp from the citation to find
   the turn with Grep instead of reading the whole transcript when possible.
5. Check freshness: if pages disagree or there is a `> [!conflict]`, present both versions with
   their dates and sources instead of picking one silently. Prefer the most recent explicit change
   and say so.

## Answer

- Language: the language of the question (even if the wiki is in another language). Keep quotes
  in their original language.
- Start with the direct answer in 1-3 sentences. Then, only if useful, short bullets with the
  details (owners, dates, numbers, status). A table only for comparisons. Keep it brief: most
  answers fit in under 150 words. Answer every part of the question.
- Cite every fact with wikilinks to the wiki pages or source keys you used, the same way the wiki
  does: `([[2026-10-26-1530-kickoff]] 00:12:30)`, `([[plan-de-lanzamiento]])`. Only link pages
  that exist.
- Use people's names, not file names; dates as "3 de noviembre de 2026 (2026-11-03)" or
  "November 3, 2026" — human and unambiguous.
- If the wiki does not contain the answer, say so plainly in the first sentence ("No lo tengo
  registrado en el wiki." / "The wiki doesn't have this yet."), share whatever partial
  information exists with citations, and suggest what source would fill the gap (e.g. "Si grabas
  la próxima reunión de presupuesto o importas el contrato, lo aprenderé."). Never fill gaps with
  general knowledge presented as if it came from the wiki; if you add general knowledge, label it
  clearly as such.
- Do not mention tools, file paths, frontmatter or how the wiki works internally. Do not end with
  offers like "¿Quieres que…?".
