# Cómo usar el brand kit en el código

Este directorio es el brand kit v1.0 de secondbrain, íntegro y sin modificar (ver `README.md`). Las reglas de producto
están en `docs/CONTRACT.md` §15. Este archivo explica dónde vive cada cosa en el repo y cómo se usa.

| Qué | Fuente (aquí) | En el código |
|---|---|---|
| Paleta y roles | `brand_tokens.json`, guía pág. 5–6 | `app/Sources/SecondBrain/Support/Brand.swift` (`Brand.color.*`), `Resources/web/wiki.css` y `graph.css` (`:root`) |
| Tipografía Inter | guía pág. 7 | `Resources/Brand/Fonts/InterVariable*.ttf` (OFL, `LICENSE-Inter.txt`), registrada en `BrandFonts.register()`; `Brand.font(...)`; `@font-face` en las WebViews |
| Símbolo (gradiente) | `02_logos/secondbrain_mark_transparent.png` (4096) | `Resources/Brand/mark-128/256/512.png`, vista `BrandMark` |
| Símbolo sólido / línea | `02_logos/secondbrain_mark_solid.svg`, `_outline.svg` | `Resources/Brand/mark-solid.svg` → ícono *template* de la barra de menús (`MenuBarLabel`) |
| Wordmark | `02_logos/secondbrain_wordmark_*.svg` (texto Inter) | `BrandWordmark` = `Text("secondbrain")` Inter Medium, tracking −0.03 em; siempre minúsculas |
| Ícono de la app | `01_icons/secondbrain.iconset` | `scripts/icon/secondbrain.iconset` → `iconutil` en `scripts/build-app.sh` |
| Ícono de bandeja | `01_icons/secondbrain_tray_*` | referencia; la app genera el template desde `mark-solid.svg` |
| Splash y fondos | `03_brand_graphics/` | animación de arranque (`LaunchOverlay`) usa el símbolo + wordmark sobre `Brand.color.bg`; los PNG 2560×1600 son referencia |
| Movimiento | `05_motion/secondbrain_motion_spec_ES.md` + storyboard | `LaunchOverlay` (A), `BrandLoader` (B), `.brandPulse()` (C); D queda pendiente |
| Mockups de UI | guía pág. 10–11 | referencia de Inicio (búsqueda, Recientes, Conexiones) |

Reglas rápidas:
1. Ningún color fuera de `Brand` (Swift) o de las variables `:root` (CSS). Nada de `.red`, `.blue`, `accentColor`, hex sueltos.
2. Ningún emoji como ícono de interfaz; SF Symbols en peso regular. El emoji del proyecto es dato del usuario.
3. Un solo rojo, apagado (`Brand.color.record`), y solo para grabar/en curso.
4. Movimiento calmado: fades y ease-out de 160–240 ms; respetar *Reducir movimiento*.
5. Antes de cambiar la marca, actualiza este kit y `docs/CONTRACT.md` §15; luego el código.
