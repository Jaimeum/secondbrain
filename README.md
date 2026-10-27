# secondbrain

Tu segundo cerebro por proyecto, 100% en tu Mac. Graba tus reuniones (audio de la computadora + tu micrófono, aunque uses audífonos), las transcribe localmente y Claude —con **tu propia cuenta**, sin API key— mantiene un wiki ordenado de cada proyecto: resúmenes, decisiones, pendientes, personas y temas. Basado en la idea *LLM Wiki* de Andrej Karpathy.

![Inicio de secondbrain: la reunión de ahora, lo que falta por ordenar y tus pendientes de hoy](docs/screenshots/home.png)

## Novedades 0.5.0

Esta versión responde a tres quejas: *las cosas se salen de lugar*, *está medio compleja* y *cuesta encontrar reuniones y notas*.

- **Nada se sale de lugar.** Todas las pantallas se revisaron a 920×620 (el nuevo tamaño mínimo de la ventana) y a 1100×720: sin textos cortados letra por letra, sin botones que empujan la barra lateral. Lo que no cabe se pliega en un menú **⋯** o pasa a una sola columna.
- **Menos conceptos.** La barra lateral queda en **Inicio · Reuniones · Correo · Pendientes · Personas** y tus proyectos. *Todo el cerebro*, *Sin asignar* y *Formatos* ya no son secciones: lo que falta por ordenar está en Inicio y los formatos en Ajustes. Cada proyecto tiene cuatro pestañas (**Contenido · Pendientes · Preguntar · Grafo**); los repositorios de GitHub están en su menú **⋯**. Hay **un solo botón de grabar**, abajo en la barra lateral (y el mismo en la barra de menús).
- **Encontrar sin pensar.** **⌘K** busca en reuniones, notas, correos, páginas, personas, pendientes y proyectos, y si no encuentra nada te deja preguntar. **Reuniones → Anteriores** lista todas tus reuniones grabadas, con o sin calendario. En cada proyecto, **Contenido → Por fecha** muestra todo lo que entró, lo más nuevo primero.
- **Inicio** reúne lo de hoy: la reunión de ahora o la siguiente, lo que falta por ordenar, los pendientes que vencen y lo reciente.
- **Pendientes** es una sola vista (en la barra lateral y dentro de cada proyecto) que muestra el **título** de la reunión o el correo de origen, nunca un nombre de archivo.
- **Correo:** "Guardar en 🚀 Proyecto" en un clic; un solo aviso a la vez, y la oferta de regla aparece después, dentro del lector.
- **Nueva identidad:** la marca es **secondbrain**, en minúsculas; nuevo símbolo e ícono, tipografía Inter, colores cálidos (marfil, olivo y un solo rojo, apagado, para grabar) y tema claro u oscuro cuidado en todas las pantallas. Animación breve de arranque y un indicador calmado mientras procesa.
- **Ajustes** en pestañas: General · Cuentas · GitHub · Reglas · Formatos · Avanzado.

## Instalar

**Necesitas:** una Mac con Apple Silicon (M1 o más nueva) con macOS 15 Sequoia o posterior, unos 5 GB libres, conexión a internet la primera vez y una suscripción de Claude **Pro o Max**. No necesitas saber programar ni tener una API key.

1. Descarga `SecondBrain-<versión>.dmg` de la página de **Releases** (sección *Assets*).
2. Ábrelo y arrastra **SecondBrain** a la carpeta **Aplicaciones** (el atajo está en la misma ventana). En el Dock y en la barra de menús se llama **secondbrain**.
3. Abre SecondBrain desde Aplicaciones. La primera vez macOS dirá que *no puede verificar* la app (no está notarizada por Apple). Pulsa **Listo**, ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso de SecondBrain y pulsa **Abrir de todos modos** (te pedirá tu contraseña). Solo se hace una vez.
4. Sigue la bienvenida:
   - **Permisos:** *Audio de la computadora* (macOS lo llama "Grabación de pantalla y audio del sistema"; no se graba tu pantalla) y *Micrófono*.
   - **Conectar Claude:** si no tienes Claude Code, secondbrain lo instala; luego se abre el navegador para que inicies sesión con tu cuenta.
   - **Modelos:** descarga el modelo de transcripción (~3 GB, una sola vez; de 2 a 10 minutos según tu internet). Puedes seguir mientras se descarga.

## Si algo no funciona

- **"No se puede abrir porque Apple no puede verificar…"** → Ajustes del Sistema → Privacidad y seguridad → **Abrir de todos modos** (paso 3). Clic derecho → Abrir ya no basta en macOS 15.
- **No graba a los demás / la transcripción solo tiene tu voz** → Ajustes del Sistema → Privacidad y seguridad → **Grabación de pantalla y audio del sistema**: activa SecondBrain. Después **cierra y vuelve a abrir** SecondBrain (macOS lo exige).
- **No graba tu voz** → Privacidad y seguridad → **Micrófono**: activa SecondBrain.
- **Claude no responde / "reconecta tu cuenta"** → abre los **Ajustes** (con la ventana de secondbrain al frente: menú *secondbrain → Ajustes…*, o ⌘,) → pestaña *Cuentas* → *Cuenta de Claude* → **Reconectar Claude** e inicia sesión de nuevo. Revisa que tu suscripción Pro/Max siga activa.
- **La descarga de modelos falló o se cortó** → pulsa **Reintentar** (o Ajustes → Avanzado → Transcripción → *Descargar ahora*). Continúa donde se quedó; no hace falta borrar nada.
- **La primera transcripción tarda en empezar** → la primera vez macOS prepara los modelos para tu chip (1–2 min). Después es inmediato.
- **Después de actualizar, vuelve a pedir permisos** → actívalos otra vez en Privacidad y seguridad (macOS los liga a cada versión de la app).

## Dónde están tus archivos

| Qué | Dónde |
|---|---|
| Tu wiki, transcripciones y notas (markdown, se abre con Obsidian) | `~/Documents/SecondBrain` (o la carpeta que elegiste; Ajustes → Avanzado → *Dónde se guarda* → *Mostrar en Finder*) |
| Ajustes de la app | `~/Library/Application Support/SecondBrain/config.json` |
| Audio pendiente de transcribir, historial de cambios y modelos (~3 GB) | `~/Library/Application Support/SecondBrain/data` |
| Conexión con Claude y con tus cuentas de correo/calendario | Llavero de macOS, elementos `app.secondbrain.mac` |
| Cuentas conectadas y proyecto de cada reunión | `~/Library/Application Support/SecondBrain/data/accounts.json`, `meetings.json` |

`~/Library` está oculta: en Finder usa **Ir → Ir a la carpeta…** (⇧⌘G) y pega la ruta.

## Desinstalar

1. Cierra secondbrain (símbolo de secondbrain en la barra de menús → Salir) y arrastra **SecondBrain** de Aplicaciones a la Papelera.
2. Borra la carpeta `~/Library/Application Support/SecondBrain` (ajustes, audio pendiente, historial y los ~3 GB de modelos).
3. *Opcional:* borra tu wiki (`~/Documents/SecondBrain` o la carpeta que elegiste) — **ahí está todo lo que aprendió; haz una copia si lo quieres conservar.**
4. *Opcional:* en **Acceso a Llaveros** busca `app.secondbrain.mac` y bórralo; en Privacidad y seguridad quita SecondBrain de *Micrófono* y *Grabación de pantalla y audio del sistema*. Claude Code (`~/.local/bin/claude`) es independiente; bórralo solo si no lo usas para nada más.

## Usar

La barra lateral tiene cinco lugares fijos y tus proyectos. **⌘1–⌘5** saltan entre ellos y **⌘K** busca en todo.

- **Inicio (⌘1):** lo de hoy, en una columna: la reunión de ahora o la siguiente (con su botón **Grabar** o **Unirme**), el resto de la agenda de hoy, **Por ordenar** (lo que llegó sin proyecto, con la sugerencia de Claude), **Pendientes para hoy**, **Recientes** y *Explorar cómo se conecta todo* (el grafo de todo tu cerebro). **Historial** (arriba a la derecha) muestra qué cambió Claude y permite **deshacer**. Arrastra un archivo a Inicio y queda en *Sin asignar*.
- **Buscar o preguntar (⌘K):** escribe parte de un título, nombre o proyecto (sin preocuparte por acentos ni mayúsculas). Resultados por grupo: Reuniones · Notas y documentos · Correos · Páginas · Personas · Pendientes · Proyectos · Acciones. ↑↓ para moverte, ↩ para abrir, esc para cerrar; la última fila siempre es **Preguntar: «…»** (⌘↩).
- **Reuniones (⌘2):** **Hoy · Próximas · Anteriores** (ver abajo).
- **Correo (⌘3):** tus mensajes recientes; **Guardar en 🚀 Proyecto ▾** los agrega al proyecto (ver abajo).
- **Pendientes (⌘4):** todos tus pendientes en una vista: **Míos · De otros · Sin dueño · Hechos**, filtro **Origen ▾** y **Exportar**. Cada pendiente muestra de qué reunión o correo salió; clic para verlo sin perder la lista.
- **Personas (⌘5):** con quién has hablado y en qué proyectos.
- **Proyecto:** cuatro pestañas.
  - **Contenido:** a la izquierda la lista **Por fecha** (todo lo que entró, lo más nuevo primero, agrupado por mes; lo que se está procesando arriba) o **Por tema** (reuniones, correos, documentos, temas, decisiones, código, personas); a la derecha la página. El resumen del proyecto va siempre arriba.
  - **Pendientes:** la misma vista de Pendientes, solo de ese proyecto.
  - **Preguntar:** pregunta lo que sea sobre el proyecto; las respuestas citan sus fuentes.
  - **Grafo:** el mapa del proyecto (ver abajo).
  - En la barra de herramientas: **+ Agregar** (Grabar aquí · Pegar correo ⇧⌘V · Nueva nota · Agregar archivos… · Pegar enlace…), **Historial** y **⋯** (formato por defecto, **Repositorios…**, Mostrar en Finder). También puedes arrastrar PDFs, textos o enlaces a cualquier parte del proyecto. Clic derecho en un proyecto de la barra lateral → *Editar proyecto…*.
- **Grabar:** hay **un solo control**, abajo en la barra lateral (y el mismo en el menú de la barra de menús): si hay una reunión en curso dice "Grabar «Kickoff…»", si no, "Grabar"; mientras graba, "Detener 12:04". Al detener se transcribe y Claude aprende de la reunión solo; la línea de abajo muestra "Procesando…" o "Transcribiendo… 42 %". Desde cualquier app: **⌥⌘R** (se activa o desactiva en Ajustes → General).
- **Sin asignar:** si no eliges proyecto, la reunión aparece en Inicio → *Por ordenar* con una sugerencia de proyecto.

![Un proyecto en Contenido → Por fecha, con la página abierta a la derecha](docs/screenshots/project-content.png)

![⌘K: buscar o preguntar](docs/screenshots/search.png)

## Ver tu cerebro (Grafo)

La pestaña **Grafo** de cada proyecto (y *Explorar cómo se conecta todo* en Inicio, para todo tu cerebro) dibuja lo que secondbrain sabe como un mapa: cada página es un punto y cada enlace una línea. En el grafo global los colores son tus proyectos; dentro de un proyecto, los colores son tipos (reuniones, correos, personas, decisiones…). Haz clic en un punto para explorar sus conexiones y abrir la página; pulsa reproducir para ver cómo creció tu cerebro con el tiempo.

## Reuniones

La sección **Reuniones** tiene tres vistas: **Hoy** (con la reunión de ahora o la siguiente arriba), **Próximas** (desde mañana, por día) y **Anteriores** (todas las reuniones que grabaste, la más reciente primero, con su proyecto y *Ver resumen*; funciona aunque no conectes un calendario).

- **Antes:** *Prepararme* te enseña quiénes van, qué quedó pendiente con ellos y qué preguntar; con *Preparar con Claude* obtienes agenda y preguntas sugeridas.
- **Durante:** cuando la reunión empieza, el botón se vuelve **Grabar** (el mismo que en la barra lateral y en la barra de menús). Título, proyecto y asistentes ya van puestos.
- **Después:** *Ver resumen* abre la página que Claude escribió, también desde *Anteriores*.

Para ver tu agenda hay dos caminos: **Usar el calendario de la Mac** (un clic, macOS te pide permiso; sirve con cualquier cuenta que ya tengas en la app Calendario) o conectar tu cuenta de Microsoft 365 / Google (abajo). *Reglas…* está en el menú **⋯** de Reuniones.

![Reuniones: la siguiente reunión y la agenda de hoy](docs/screenshots/meetings.png)

## Conectar correo y calendario (Microsoft 365 / Google)

En **Ajustes → Cuentas** (o desde las secciones *Correo* y *Reuniones*) pulsa **Conectar Microsoft 365** o **Conectar Google**. Se abre tu navegador, inicias sesión y listo. secondbrain **solo lee**: nunca envía, borra ni mueve nada, y tu correo se queda en tu Mac. Puedes desconectar cuando quieras.

- **Correo:** en la sección *Correo* ves tus mensajes recientes y con un botón los guardas en el proyecto que elijas ("Guardar en 🚀 Proyecto ▾"). Si el mensaje es parte de un hilo, se guarda completo. Siempre puedes deshacer ("Aprendiendo del correo… · Deshacer"). Con más de una cuenta conectada, el selector de cuenta está arriba de la lista.
- **Tu organización bloquea la conexión** ("necesita aprobación del administrador", "access blocked"): pulsa **¿Problemas para conectar tu cuenta del trabajo?** (Ajustes → Cuentas) o **¿Cómo lo habilito?** en el aviso de bloqueo. Ahí tienes un mensaje listo para enviarle a TI (botón *Pedírselo a TI*) y los pasos exactos para el administrador:
  - *Microsoft 365:* en el centro de administración de Microsoft Entra, abrir `https://login.microsoftonline.com/common/adminconsent?client_id=<ID de la app>` y **Aceptar**, o en *Aplicaciones empresariales → Consentimiento y permisos* permitir que los usuarios den consentimiento a permisos de bajo impacto. Permisos pedidos: `User.Read`, `Mail.Read`, `Calendars.Read`, `offline_access` (todos delegados, solo lectura).
  - *Google Workspace:* en la consola de administración, *Seguridad → Control de acceso y datos → Controles de API → Gestionar acceso de aplicaciones de terceros → Añadir aplicación* → buscar por ID de cliente → marcar **De confianza**. Permisos pedidos: `gmail.readonly`, `calendar.readonly`, `openid email profile`.
  - Mientras tanto, puedes seguir pegando correos (*Edición → Pegar correo…*, ⇧⌘V) y usar el calendario de la Mac.
- **Registro de la aplicación (solo para quien distribuye SecondBrain):** la conexión usa OAuth con un *ID de cliente* por proveedor. Se crea una vez y **no va en el código**: `scripts/build-app.sh` lo inyecta en el `.app` desde `secrets/` en el repo (ignorada por git; si no existe, `~/.config/secondbrain/`) (`google-client.json` = el archivo `client_secret_….json` que descarga Google Cloud, tal cual; `microsoft-client-id.txt` = el *Id. de aplicación (cliente)* de Entra, una línea). Para probar sin compilar: *Ajustes → Avanzado → Registro propio de apps* o variables `SB_MS_CLIENT_ID`, `SB_GOOGLE_CLIENT_ID`, `SB_GOOGLE_CLIENT_SECRET`:
  - *Microsoft:* Entra → *Registros de aplicaciones → Nuevo registro* → cuentas en cualquier directorio y personales → plataforma *Aplicaciones móviles y de escritorio* con URI `http://localhost` → *Autenticación → Permitir flujos de cliente público: Sí* → *Permisos de API*: `User.Read`, `Mail.Read`, `Calendars.Read`, `offline_access` → copia el *Id. de aplicación (cliente)*.
  - *Google:* Google Cloud → *Pantalla de consentimiento OAuth* (interna si es Workspace; externa + usuarios de prueba si no) con los permisos de Gmail y Calendar de solo lectura → *Credenciales → Crear ID de cliente OAuth → Aplicación de escritorio* → copia el ID y el secreto de cliente.

## Conectar tus repositorios de GitHub

En **Ajustes → GitHub** pulsa **Conectar GitHub** (código de dispositivo en tu navegador, **Usar mi sesión de GitHub CLI** o pegar un token). Después, en cada proyecto abre **⋯ → Repositorios…** (en la barra de herramientas del proyecto) y agrega los repositorios que quieras: **varios por proyecto**, y de cada uno **solo las ramas que elijas** (por ejemplo `main` y `development`). Lo demás del repo se ignora.

- **Actualización automática:** secondbrain revisa tus ramas cada cierto tiempo (por defecto cada 60 minutos; lo cambias en Ajustes). Es incremental: si nada cambió, no hace nada. Si alguien reescribe una rama (force-push, rebase) o la borra, lo detecta y lo anota.
- **Qué aprende:** commits de cada rama, pull requests, issues, releases, y las diferencias entre ramas (qué está en `development` y todavía no en `main`). El código de las ramas elegidas se guarda en tu Mac para poder responder preguntas sobre él.
- **Privacidad:** acceso de **solo lectura** (nunca hace push, comentarios ni cambios). El código se queda en tu Mac; a Claude solo llega el texto que necesita para responder, a través de tu cuenta.
- **Preguntas que cruzan código con correos y reuniones:**
  - "¿Lo que pidió Ana en el correo ya está en development?"
  - "Prepárame la llamada de alcance con lo que cambió esta semana."
  - "¿Qué PRs siguen abiertos y qué dijo el cliente sobre ellos?"
- **Terminal:** `sb github status`, `sb github login --gh|--device|--token -` (`--token -` reads the token from stdin, e.g. `pbpaste | sb github login --token -`), `sb github logout`, `sb github add`, `sb github remove`, `sb github sync [--project] [--repo] [--if-due]`.
- **Organizaciones que restringen apps:** si tu organización exige aprobación, pídele a un admin aprobar SecondBrain (Third-party access policy) o autoriza el token con SAML SSO.

## Reglas: cada correo y reunión a su proyecto

Si todo te llega a una sola cuenta, las **Reglas** (Ajustes → Reglas, o *Reglas…* en el menú **⋯** de Correo y de Reuniones) deciden a qué proyecto va cada cosa: "lo que venga de @acme.com va a 🚀 Acme", "si el asunto dice Nubia va a 🤝 Alianza", "las reuniones que organiza ana@acme.com…". Gana la primera que coincide; lo que no coincide con ninguna cae en *Sin asignar* (o en el proyecto por defecto que elijas) y lo asignas a mano. Cada vez que asignas algo a mano, secondbrain te propone la regla con un clic ("¿Mandar siempre lo de @acme.com a 🚀 Acme? · Sí, siempre · Solo esta vez"). Las reglas se reordenan arrastrándolas. Una regla puede además **agregar automáticamente** los correos nuevos que coincidan, revisando tu correo cada 15 minutos.

## Apariencia

**Ajustes → General → Apariencia**: *Sistema*, *Claro* u *Oscuro* (también en el menú *Ver*). Cambia al instante, también en las páginas y el grafo. La app usa la identidad de **secondbrain**: nombre siempre en minúsculas, tipografía Inter, fondos marfil (claro) o verde tinta (oscuro), olivo para las acciones y un solo rojo, apagado, para grabar. La ventana mide como mínimo 920×620.

## Privacidad

El audio se transcribe en tu Mac y se borra después. Las transcripciones y el wiki son archivos markdown en tu carpeta (por defecto `~/Documents/SecondBrain`, compatible con Obsidian). Lo único que sale de tu Mac es el texto que Claude lee para escribir el wiki, a través de tu cuenta. Si grabas a otras personas, pide su consentimiento.

## Desarrollo

```bash
cd app && swift build                 # compila (solo Command Line Tools)
scripts/make-dev-cert.sh              # identidad de firma local (permisos estables entre builds)
scripts/build-app.sh [--release]      # build/SecondBrain.app (+ dist/*.zip y *.dmg con --release); ícono desde scripts/icon/secondbrain.iconset
scripts/release.sh <versión>          # publica en GitHub Releases
```

- **Arquitectura y contrato entre módulos:** `docs/CONTRACT.md`. Los módulos son `Recorder`, `Transcription` (WhisperKit + SpeakerKit), `BrainCore` (cola, Claude, historial, vault), `SecondBrain` (UI) y `sb` (CLI).
- **El esquema del cerebro** está en `app/Sources/BrainCore/Resources/vault-template/`.
- **Marca:** el kit está en `docs/brand/` y su uso en código en `docs/brand/USAGE.md`; todos los colores y fuentes salen de `app/Sources/SecondBrain/Support/Brand.swift` (y de las variables `:root` de `wiki.css`/`graph.css`). Reglas de UX y layout de la v0.5: `docs/CONTRACT.md` §15.
- **Nombre:** el ejecutable y el paquete siguen siendo `SecondBrain` / `SecondBrain.app`; lo que ve el usuario (`CFBundleName`, `CFBundleDisplayName`, textos) es `secondbrain`.
- **Capturas para revisar la UI:** `SB_SNAPSHOT_DIR=<carpeta>` renderiza cada vista a PNG y sale; con `SB_SNAPSHOT_WINDOW=1` renderiza la ventana completa (1100×720 y 920×620, claro y oscuro); `SB_SNAPSHOT_ONLY=<prefijo>` limita cuáles; `SB_DEMO_ACCOUNTS=1` y `SB_DEMO_GITHUB=1` usan datos de ejemplo.

---

**English:** secondbrain records your meetings locally (system audio + mic), transcribes them on-device, and uses your own Claude account (via Claude Code) to maintain a per-project markdown wiki.

- **Install:** requires an Apple Silicon Mac on macOS 15+, ~5 GB free and a Claude Pro/Max plan. Open the `.dmg`, drag SecondBrain to Applications and open it. When macOS says it can't verify the app (not notarized), go to *System Settings → Privacy & Security* and click **Open Anyway** (*Abrir de todos modos*). Then grant *System Audio Recording* and *Microphone*, connect Claude (browser sign-in) and let it download the transcription model (~3 GB, once).
- **Troubleshooting:** no other voices in the transcript → enable SecondBrain under *Privacy & Security → Screen & System Audio Recording* and reopen the app; Claude errors → *secondbrain → Settings… (⌘,) → Accounts → Claude account → Reconnect Claude*; a failed model download resumes with *Retry*.
- **Files:** wiki in `~/Documents/SecondBrain` (or the folder you chose); settings, pending audio, history and models in `~/Library/Application Support/SecondBrain`; the Claude token in the Keychain (`app.secondbrain.mac`).
- **What's new in 0.5.0:** a lowercase **secondbrain** identity (new mark and icon, Inter, warm light and dark themes, one muted red for recording) and a simpler app. The sidebar is *Home · Meetings · Mail · Tasks · People* plus your projects; **⌘K** searches meetings, notes, mail, pages, people, tasks and projects (or asks); *Meetings* is *Today · Upcoming · Past* (Past lists every recorded meeting, calendar or not); a project has four tabs (*Content* by date or by topic, *Tasks*, *Ask*, *Graph*) with *+ Add*, *History* and *⋯ → Repositories…* in its toolbar; there is a single record control at the bottom of the sidebar; *Settings* has tabs (General · Accounts · GitHub · Rules · Formats · Advanced). Every screen fits a 920×620 window without clipping.
- **v0.3:** *Graph* tab (your brain as a map, colored by project or by type, with a time replay), *Meetings* (agenda from the Mac Calendar or a connected account; prepare with Claude, record with one click, open the summary), *Mail* (read recent messages from Microsoft 365 / Google and add them to a project; read-only), and Light/Dark/System appearance. If your organization blocks the sign-in, open **Trouble connecting a work account?** (Settings → Accounts) or **How do I enable it?** on the block notice for a ready-to-send message to IT and the exact admin steps (Microsoft: admin consent URL; Google: Admin console → Security → API controls → Manage Third-Party App Access → Trusted). Distributors must register an OAuth client per provider and put the ids in `OAuthDefaults` (or Settings → Advanced).
- **Uninstall:** quit, delete the app, delete `~/Library/Application Support/SecondBrain`, and optionally your wiki folder (back it up first) and the `app.secondbrain.mac` Keychain item.
