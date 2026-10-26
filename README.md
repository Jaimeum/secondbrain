# SecondBrain

Tu segundo cerebro por proyecto, 100% en tu Mac. Graba tus reuniones (audio de la computadora + tu micrófono, aunque uses audífonos), las transcribe localmente y Claude —con **tu propia cuenta**, sin API key— mantiene un wiki ordenado de cada proyecto: resúmenes, decisiones, pendientes, personas y temas. Basado en la idea *LLM Wiki* de Andrej Karpathy.

## Instalar

**Necesitas:** una Mac con Apple Silicon (M1 o más nueva) con macOS 15 Sequoia o posterior, unos 5 GB libres, conexión a internet la primera vez y una suscripción de Claude **Pro o Max**. No necesitas saber programar ni tener una API key.

1. Descarga `SecondBrain-<versión>.dmg` de la página de **Releases** (sección *Assets*).
2. Ábrelo y arrastra **SecondBrain** a la carpeta **Aplicaciones** (el atajo está en la misma ventana).
3. Abre SecondBrain desde Aplicaciones. La primera vez macOS dirá que *no puede verificar* la app (no está notarizada por Apple). Pulsa **Listo**, ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso de SecondBrain y pulsa **Abrir de todos modos** (te pedirá tu contraseña). Solo se hace una vez.
4. Sigue la bienvenida:
   - **Permisos:** *Audio de la computadora* (macOS lo llama "Grabación de pantalla y audio del sistema"; no se graba tu pantalla) y *Micrófono*.
   - **Conectar Claude:** si no tienes Claude Code, SecondBrain lo instala; luego se abre el navegador para que inicies sesión con tu cuenta.
   - **Modelos:** descarga el modelo de transcripción (~3 GB, una sola vez; de 2 a 10 minutos según tu internet). Puedes seguir mientras se descarga.

## Si algo no funciona

- **"No se puede abrir porque Apple no puede verificar…"** → Ajustes del Sistema → Privacidad y seguridad → **Abrir de todos modos** (paso 3). Clic derecho → Abrir ya no basta en macOS 15.
- **No graba a los demás / la transcripción solo tiene tu voz** → Ajustes del Sistema → Privacidad y seguridad → **Grabación de pantalla y audio del sistema**: activa SecondBrain. Después **cierra y vuelve a abrir** SecondBrain (macOS lo exige).
- **No graba tu voz** → Privacidad y seguridad → **Micrófono**: activa SecondBrain.
- **Claude no responde / "reconecta tu cuenta"** → abre los **Ajustes** de SecondBrain (con la ventana de SecondBrain al frente: menú *SecondBrain → Ajustes…*, o ⌘,) → *Claude* → **Reconectar Claude** e inicia sesión de nuevo. Revisa que tu suscripción Pro/Max siga activa.
- **La descarga de modelos falló o se cortó** → pulsa **Reintentar** (o Ajustes → Transcripción → *Descargar ahora*). Continúa donde se quedó; no hace falta borrar nada.
- **La primera transcripción tarda en empezar** → la primera vez macOS prepara los modelos para tu chip (1–2 min). Después es inmediato.
- **Después de actualizar, vuelve a pedir permisos** → actívalos otra vez en Privacidad y seguridad (macOS los liga a cada versión de la app).

## Dónde están tus archivos

| Qué | Dónde |
|---|---|
| Tu wiki, transcripciones y notas (markdown, se abre con Obsidian) | `~/Documents/SecondBrain` (o la carpeta que elegiste; Ajustes → *Dónde se guarda* → *Mostrar en Finder*) |
| Ajustes de la app | `~/Library/Application Support/SecondBrain/config.json` |
| Audio pendiente de transcribir, historial de cambios y modelos (~3 GB) | `~/Library/Application Support/SecondBrain/data` |
| Conexión con Claude | Llavero de macOS, elemento `app.secondbrain.mac` |

`~/Library` está oculta: en Finder usa **Ir → Ir a la carpeta…** (⇧⌘G) y pega la ruta.

## Desinstalar

1. Cierra SecondBrain (menú 🧠 → Salir) y arrastra **SecondBrain** de Aplicaciones a la Papelera.
2. Borra la carpeta `~/Library/Application Support/SecondBrain` (ajustes, audio pendiente, historial y los ~3 GB de modelos).
3. *Opcional:* borra tu wiki (`~/Documents/SecondBrain` o la carpeta que elegiste) — **ahí está todo lo que aprendió; haz una copia si lo quieres conservar.**
4. *Opcional:* en **Acceso a Llaveros** busca `app.secondbrain.mac` y bórralo; en Privacidad y seguridad quita SecondBrain de *Micrófono* y *Grabación de pantalla y audio del sistema*. Claude Code (`~/.local/bin/claude`) es independiente; bórralo solo si no lo usas para nada más.

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

**English:** SecondBrain records your meetings locally (system audio + mic), transcribes them on-device, and uses your own Claude account (via Claude Code) to maintain a per-project markdown wiki.

- **Install:** requires an Apple Silicon Mac on macOS 15+, ~5 GB free and a Claude Pro/Max plan. Open the `.dmg`, drag SecondBrain to Applications and open it. When macOS says it can't verify the app (not notarized), go to *System Settings → Privacy & Security* and click **Open Anyway** (*Abrir de todos modos*). Then grant *System Audio Recording* and *Microphone*, connect Claude (browser sign-in) and let it download the transcription model (~3 GB, once).
- **Troubleshooting:** no other voices in the transcript → enable SecondBrain under *Privacy & Security → Screen & System Audio Recording* and reopen the app; Claude errors → *SecondBrain → Settings… (⌘,) → Claude → Reconnect Claude*; a failed model download resumes with *Retry*.
- **Files:** wiki in `~/Documents/SecondBrain` (or the folder you chose); settings, pending audio, history and models in `~/Library/Application Support/SecondBrain`; the Claude token in the Keychain (`app.secondbrain.mac`).
- **Uninstall:** quit, delete the app, delete `~/Library/Application Support/SecondBrain`, and optionally your wiki folder (back it up first) and the `app.secondbrain.mac` Keychain item.
