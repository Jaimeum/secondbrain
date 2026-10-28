---
description: After the owner edited a page by hand, find the other pages that still say what they corrected (read-only, JSON output)
argument-hint: <JSON {"path", "title", "project", "diff"}>
---

# Propagate the owner's correction

Arguments: `$ARGUMENTS`

The owner of this vault just edited a wiki page by hand in the SecondBrain app and saved it. Their
edit is a **correction**: what they removed was wrong, what they wrote is right (CLAUDE.md §17).
Your job: say which facts they confirmed, and find every OTHER page of the cerebro that still says
the wrong thing, proposing the exact text to change. **Read-only: do not create, edit or delete
any file.** The app shows your proposals to the owner, who chooses which ones to apply. Never ask
questions.

The arguments are one JSON object:
- `path`: the page they edited (vault-relative), already saved with their changes;
- `title`: its title; `project`: its project slug, or null for a global page;
- `diff`: what changed, as lines starting with `-` (removed), `+` (added) and two spaces (context).

## Steps

1. Read `CLAUDE.md` (vault root) if it is not in your context, and `facts.md` (facts already
   confirmed). Read the edited page as it is now.
2. Understand the correction from the diff. If it only changes wording, formatting, typos or
   adds something without correcting anything, there is nothing to propagate: answer
   `{"facts":[],"edits":[]}`.
3. Write the **facts**: 1-3 short, self-contained sentences stating what is true now, with full
   names (never "él", "este proyecto"), in the language of the edited page, ending with the
   wikilinks of the pages they are about: `Javier Ruiz no forma parte del equipo de Angela Torres.
   ([[javier-ruiz]], [[angela-torres]])`. Only what the owner's edit says; never add your own
   inferences. Don't repeat a fact already in `facts.md`.
4. Find every other page that still states or relies on the old, wrong version. Grep the wiki for
   the names, aliases (people `aliases:`, org names, email addresses) and key words of the
   correction, in Spanish and English: `projects/*/wiki/**`, `people/`, `orgs/`, `index.md`,
   `questions/`. Typical places: the person and org pages involved, overviews ("Personas",
   "Estado actual", glossary), topics, decisions, tasks (owner of a task), meeting and email pages,
   timeline lines, indexes.
   Skip: the edited page itself, `raw/`, `_inbox/`, `templates/`, `CLAUDE.md`, `facts.md`,
   `log.md` / `wiki/log.md` (history, never rewritten), `.secondbrain/`.
5. For each page, propose the **smallest edit** that makes it agree with the correction:
   - `before`: text copied **exactly, character for character** from the page as it is now —
     one or more whole lines, enough to be unique in that page. Never paraphrase it.
   - `after`: the same lines corrected. Keep the page's language, style, links and citations;
     where the corrected claim has no source any more, cite `([[facts|Hechos confirmados]])`.
     Keep frontmatter valid YAML (e.g. remove a wrong person from `people:`).
   - On a meeting, email or source page, what someone **said** stays as said: don't rewrite a
     quote or "Ana dijo que…"; correct only the wiki's own statements, and if needed add right
     after the line: `> [!note] Corregido por ti: …`.
   - `reason`: one short sentence for the owner, in the page's language ("Decía que Javier era
     del equipo de Angela").
   - One entry per change; several entries for the same page are fine if they are far apart.
   - At most 30 edits. Never invent facts beyond the correction.

## Output

Your entire final message must be exactly ONE JSON object and nothing else — no code fence, no
text before or after:

{"facts":["Javier Ruiz no forma parte del equipo de Angela Torres. ([[javier-ruiz]], [[angela-torres]])"],"edits":[{"path":"people/angela-torres.md","before":"- **Equipo:** [[javier-ruiz|Javier Ruiz]], [[sofia-mora|Sofía Mora]]","after":"- **Equipo:** [[sofia-mora|Sofía Mora]]","reason":"Ponía a Javier en el equipo de Angela."}]}

If nothing else needs to change, `edits` is `[]` (the facts are still recorded).
