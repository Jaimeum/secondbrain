# SecondBrain

Tu segundo cerebro por proyecto, 100% en tu Mac. Graba tus reuniones (audio de la computadora + tu micrófono, aunque uses audífonos), las transcribe localmente y Claude —con **tu propia cuenta**, sin API key— mantiene un wiki ordenado de cada proyecto: resúmenes, decisiones, pendientes, personas y temas. Basado en la idea *LLM Wiki* de Andrej Karpathy.

## Instalar

1. Descarga `SecondBrain-<versión>.dmg` de Releases y arrastra **SecondBrain** a Aplicaciones.
2. Ábrela. La primera vez macOS la bloquea (no está notarizada): ve a **Ajustes del Sistema → Privacidad y seguridad** y pulsa **Abrir de todos modos**. Solo se hace una vez.
3. Sigue la bienvenida: permisos de grabación y micrófono, conectar tu cuenta de Claude (se abre el navegador) y descarga de modelos (~3 GB, una sola vez).

**Requisitos:** macOS 15 o superior, Mac con Apple Silicon, cuenta de Claude Pro o Max.

## Usar

- **Grabar:** botón 🧠 en la barra de menú (o ⌥⌘R) → elige el proyecto → Grabar. Al detener, se transcribe y Claude "aprende" de la reunión solo.
- **Sin asignar:** si no eliges proyecto, la reunión queda en *Sin asignar* con una sugerencia de proyecto.
- **Otras fuentes:** arrastra PDFs, textos o enlaces a un proyecto, o escribe una nota.
- **Preguntar:** pregunta lo que sea sobre un proyecto o todo tu cerebro; las respuestas citan sus fuentes.
- **Actividad:** ve qué cambió Claude en cada paso y **deshaz** cuando quieras.

## Privacidad

El audio se transcribe en tu Mac y se borra después. Las transcripciones y el wiki son archivos markdown en tu carpeta (por defecto `~/Documents/SecondBrain`, compatible con Obsidian). Lo único que sale de tu Mac es el texto que Claude lee para escribir el wiki, a través de tu cuenta. Si grabas a otras personas, pide su consentimiento.

## Desarrollo

```bash
cd app && swift build                 # compila (solo Command Line Tools)
scripts/make-dev-cert.sh              # identidad de firma local (permisos estables entre builds)
scripts/build-app.sh [--release]      # build/SecondBrain.app (+ dist/*.zip y *.dmg con --release)
scripts/release.sh <versión>          # publica en GitHub Releases
```

- **Arquitectura y contrato entre módulos:** `docs/CONTRACT.md`. Los módulos son `Recorder`, `Transcription` (WhisperKit + SpeakerKit), `BrainCore` (cola, Claude, historial, vault), `SecondBrain` (UI) y `sb` (CLI).
- **El esquema del cerebro** está en `app/Sources/BrainCore/Resources/vault-template/`.

---

**English:** SecondBrain records your meetings locally (system audio + mic), transcribes them on-device, and uses your own Claude account (via Claude Code) to maintain a per-project markdown wiki. Install the `.dmg`, then allow it under *System Settings → Privacy & Security → Open Anyway*. Requires macOS 15+, Apple Silicon and a Claude Pro/Max plan.
