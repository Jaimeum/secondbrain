---
description: Health-check the wiki, fix trivial issues and write a health report
argument-hint: <project-slug | global>
---

# Health check ("Revisar mi cerebro")

Scope: `$ARGUMENTS`

Check the wiki for problems, fix what is safe to fix, and write a report a non-technical person
can act on. Follow `CLAUDE.md` at the vault root. **Never invent facts**: you can reorganize,
link and flag, but every content change must come from what the wiki or raw sources already say.
Never ask questions. Never touch `raw/` or `_inbox/`.

## Scope

- A project slug → the pages under `projects/<slug>/wiki/` plus the `people/` pages of people in
  that project. Report: `projects/<slug>/wiki/health.md`.
- `global` → `index.md`, `log.md`, `people/`, cross-project consistency (same person described
  differently in two projects, duplicate people pages), and a light pass over every project's
  `wiki/index.md`. Report: `health.md` at the vault root.

## Checks

1. **Broken links**: Grep `\[\[` in the scoped pages; every target must exist (bare names
   anywhere in the vault, path links at that path, ignoring `|label` and `#heading`).
2. **Index coverage**: every page in the scope is listed in its index; every index line points to
   an existing page.
3. **Orphans**: pages with no inbound links from other wiki pages (index doesn't count for topics
   and decisions).
4. **Frontmatter**: missing `type`, `title`, `updated`, `sources` (log pages need only `type` and
   `title`; navigation pages have no `sources` requirement); invalid YAML; title ≠ H1.
5. **Uncited claims**: bullets with facts but no citation in meeting, source, topic, decision and
   person pages (sample the pages; don't rewrite them).
6. **Contradictions**: open `> [!conflict]` callouts (list them), and contradictions between pages
   that nobody flagged (e.g. overview says one date, a decision page another).
7. **Stale content**: overview "Estado actual" or topic "En breve" older than newer sources that
   changed it; decisions still `accepted` although a later decision supersedes them.
8. **Tasks** (in `tasks.md`, the only live list; meeting pages are a snapshot of that day and are
   not compared): open tasks whose date is before today (overdue); tasks without owner;
   duplicates; tasks a later source says are done but still open; checkboxes outside `tasks.md`
   (convert them to plain bullets).
9. **Missing pages**: people, topics or terms mentioned in 3+ pages without a page of their own;
   glossary terms used but undefined.
10. **Duplicates**: two pages about the same person/topic (aliases, accents, languages).
11. **Unmapped speakers**: meetings with `person: null` labels where another source now gives
    clear evidence (only report; map them only if the evidence meets CLAUDE.md §7).
12. **Unprocessed sources**: raw files in the project with no source page in `wiki/meetings/` or
    `wiki/sources/` (report only; the app ingests them).

## Fix (only trivial, safe things)

- Broken link where the intended target is obvious (typo, accent, old name, `.md` suffix) → fix
  it; otherwise turn it into plain text and report it.
- Missing index lines → add them; index lines pointing to nothing → remove them.
- Missing `updated`/`type`/`title` frontmatter → add from the page content.
- Exact duplicate tasks in `tasks.md` → merge; tasks done in a source but open in `tasks.md` →
  mark done with citation.
- Orphan topic/decision → link it from the most relevant topic or the overview if the connection
  is clear from content.
- Do NOT: resolve contradictions, merge different-looking people/topic pages, rewrite summaries,
  delete pages, or create content pages. Report those instead.
- Set `updated:` to today on pages you change.

## Report

Overwrite the report file with this structure, in the project's navigation language:

```markdown
---
type: health
title: "Estado del wiki"
project: <slug or null>
updated: <today>
language: es
---

# Estado del wiki

> **En breve:** one or two sentences: overall health and the 1-3 things the owner should do.

## Arreglado automáticamente
- …

## Para revisar
- **Contradicción:** … (links)
- **Pendiente vencido:** … — owner · 📅 date (link)

## Sugerencias
- Sources or meetings that would fill gaps; questions worth asking; pages worth creating.

## Números
Páginas: N · Reuniones: N · Fuentes: N · Decisiones: N · Pendientes abiertos: N (vencidos: N) · Conflictos abiertos: N
```

Omit empty sections except "En breve" and "Números". Then append to the project `wiki/log.md`
(project scope) and to `log.md`: `## [today] lint | Revisión del wiki` + 1-2 bullets (fixed N,
to review N).

## Final message

Start directly with the first bullet. 3-5 short bullet lines in the project's language for a
non-technical user, addressing the owner as "tú"/"you": overall state, what
you fixed, what needs their attention. No file paths, no tool talk.
