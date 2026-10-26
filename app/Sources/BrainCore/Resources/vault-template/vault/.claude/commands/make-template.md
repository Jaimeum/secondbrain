---
description: Create a page template ("formato") from a plain-language description
argument-hint: '{"name": "...", "id": "...", "description": "..."}'
---

# Create a template from a description

Arguments (JSON): `$ARGUMENTS`

The owner described, in their own words, how they want the summaries of their meetings (or
email threads) to look. Turn that into a template file that you (and future ingests) will follow.
Read `CLAUDE.md` at the vault root, §11 (templates), §10 (Acuerdos) and §8.1 / §8.8 (the standard
formats), and Read `templates/estandar.md` and one more template in `templates/` as examples of
style. Never ask questions.

## Steps

1. Parse the JSON: `name` (shown in the app), `id` (filename stem), `description` (what the
   owner wants). If `id` is empty, make one from the name: lowercase kebab-case ASCII.
2. Destination: `templates/<id>.md`. If that file exists and its frontmatter says
   `builtin: true`, write `templates/<id>-mio.md` instead (never overwrite a built-in format); if
   it exists with `builtin: false`, overwrite it (the owner is redoing their own format).
3. Decide the `scope`: `email` if the description is about emails/threads only, `meeting` if it
   is about meetings/calls only, otherwise `any`.
4. Design the body from the description: what sections, in what order, how long, what to
   emphasize, what to leave out. Headings in the language of the description. Each `##` heading
   is followed by one `<!-- … -->` comment with short, concrete instructions (what goes there,
   format of bullets, length limits). Keep what the owner asked for and nothing they didn't.
   - The app always adds the frontmatter, title, date line, citations and `## Fuente` by itself:
     do not put them in the template.
   - Always include a `## Acuerdos` section with `### Mis compromisos`, `### Compromisos de los
     demás`, `### Acordado entre todos` (in the description's language), placed where it fits
     the owner's description; its comment says "dueño y fecha en cada compromiso".
   - No example facts, names or dates in the template (only instructions). No other HTML.
5. Write the file:

```markdown
---
type: template
name: "<name>"
description: "<one sentence, in the owner's language, saying what this format is for>"
scope: meeting
builtin: false
---

## <Heading>
<!-- instructions -->

## Acuerdos
<!-- … -->
### Mis compromisos
### Compromisos de los demás
### Acordado entre todos
```

6. Do not edit any other file (no log entry, no index).

## Final message

Exactly one short line in the description's language, no file paths, e.g.
"Listo: creé el formato «Seguimiento con clientes» (necesidades, objeciones, acuerdos y próximos pasos)."
