# Pendientes

## 0. ~~Registrar SecondBrain en GitHub (OAuth App con Device Flow)~~ ✅ Hecho (2026-10-27)

OAuth App `SecondBrain` creada con Device Flow activado. Client ID en `secrets/github-client-id.txt` (ignorado por git);
`build-app.sh` lo inyecta en `oauth-defaults.json` como `githubClientId`. Para probar sin compilar: `SB_GITHUB_CLIENT_ID=<id>`.

Nota para organizaciones: si la organización tiene la **Third-party access policy** (restricción de OAuth Apps), un owner debe aprobar SecondBrain en Settings → Third-party Access → OAuth app policy. Si usa SAML SSO, hay que **Authorize** el token/la app para esa organización.

## 1. ~~Registrar SecondBrain en Microsoft (para "Conectar Microsoft 365")~~ ✅ Hecho (2026-10-27)

App `SecondBrain` registrada en Entra (directorio personal "Default Directory"; una cuenta personal de Microsoft no puede
registrar apps sin directorio). Multiinquilino + cuentas personales, redirect `http://localhost` (cliente público), "Allow
public client flows" activado, permisos **Delegated** de Graph: `User.Read`, `Mail.Read`, `Calendars.Read`, `offline_access`
(ningún permiso de tipo Application). Client ID en `secrets/microsoft-client-id.txt` (ignorado por git); `build-app.sh` lo
inyecta como `microsoftClientId`. Para probar sin compilar: `SB_MS_CLIENT_ID=<id>`.

- [ ] Probar "Conectar Microsoft 365" en vivo (cuenta personal y de trabajo) con la app compilada.
- Opcional: verificación de editor (Partner Center) para que menos organizaciones bloqueen la app por defecto.

## 2. Google: salir del modo "En pruebas"

El registro ya está hecho (archivo en `secrets/google-client.json` del repo, ignorado por git; incluido desde 0.3.1). Mientras la app esté
"En pruebas", solo entran los correos agregados como usuarios de prueba (máx. 100) y Google muestra "app no verificada".

Cuando haya usuarios: Google Cloud → Google Auth Platform → **Centro de verificación** → enviar a verificación.
`calendar.readonly` solo pide la verificación normal; `gmail.readonly` es permiso restringido y pide además una
auditoría de seguridad externa (CASA, de pago). Alternativa si pesa: publicar solo con calendario y dejar Gmail para después.

## 3. Probar la v0.5 en vivo

Las capturas (`SB_SNAPSHOT_DIR`, `SB_SNAPSHOT_WINDOW=1`) cubren el layout a 920×620 y 1100×720 en claro y oscuro, pero
no lo que se mueve, se arrastra o depende de AppKit. Revisar a mano con la app compilada:

- [ ] **Barra de herramientas del proyecto:** menú **+ Agregar** (Grabar aquí · Pegar correo · Nueva nota · Agregar
      archivos… · Pegar enlace…), **Historial** (abre la hoja del proyecto) y **⋯** (Formato por defecto ▸ ·
      Repositorios… · Mostrar en Finder). Que se pliegue en ⋯ al angostar la ventana.
- [ ] **Una sola columna** en Correo y Reuniones: con el detalle por debajo de 620/700 pt, lista y lector/detalle pasan a
      una columna (push) y se puede volver atrás sin perder la selección.
- [ ] **Arrastrar reglas** para reordenarlas (Ajustes → Reglas y la hoja *Reglas…* del menú ⋯ de Correo y Reuniones);
      el orden se guarda y la primera que coincide gana.
- [ ] **Animación de arranque** (1.6 s, una vez por lanzamiento; no al cambiar de cerebro) y con *Reducir movimiento*
      activado (solo fade).
- [ ] **Icono de la barra de menús al grabar:** símbolo + punto `record`; vuelve al template al detener; se ve bien con
      barra de menús clara y oscura.
- [ ] **Reparar permiso** (0.5.3): al pasar de 0.5.2 a 0.5.3, Grabar → aviso → *Reparar permiso* → macOS pide micrófono
      y grabación otra vez → activar → *Salir y volver a abrir* → graba. Y que 0.5.4 ya no lo pida.
- [ ] **⌘K con teclado:** abre desde cualquier pantalla (no sobre una hoja), ↑↓ ↩ esc, ⌘↩ pregunta, ⌥ pregunta al
      proyecto actual; foco en el campo al abrir.
- [ ] **Ajustes abre en la pestaña pedida** (Reglas…, Formatos, GitHub, Cuentas desde avisos y desde ⌘K), también si
      la ventana de Ajustes ya estaba abierta en otra pestaña.
- [ ] **Modo oscuro de la tira de pestañas de Ajustes** (iconos y etiqueta seleccionada legibles).
- [ ] Pendiente de v0.4: GitHub real (dos ramas a la vez, force-push / rebase, rama borrada, cambios de PRs e issues
      entre dos sincronizaciones) y conectar con `gh`, token y Device Flow. Hoy solo lo cubre `sb github selftest`.

## 3a. Probar la v0.6 en vivo

Las capturas no cubren lo que depende de AppKit, de macOS o de Claude. Con la app compilada:

- [ ] **/propagate real desde el editor de la app:** editar una página → *Revisar cambios en el cerebro* → aplicar →
      `facts.md` y Historial (deshacer). Una corrida por CLI el 2026-10-27 ya funcionó: Claude encontró las dos páginas
      y propuso el hecho correcto; falta verla de punta a punta en la app.
- [ ] **⌥⌘N:** se registra al abrir la app, Ajustes → General permite cambiarlo (grabar otro atajo, rechazar los de
      macOS y ⌥⌘R) y desactivarlo; y que "Nueva carpeta inteligente" del Finder deje de responder mientras está activo.
- [ ] **Panel de captura rápida con varios monitores:** aparece en el monitor del cursor, toma el foco al abrir, esc lo
      cierra y devuelve el foco a la app anterior; no activa la ventana principal.
- [ ] **Primer Grabar con la ventana principal cerrada:** hoja explicativa → permisos de micrófono y grabación →
      descarga del modelo → graba (también desde ⌥⌘R y la barra de menús).
- [ ] **Barras de herramientas** (no aparecen en las capturas): Proyecto (+ Agregar, Historial, ⋯), Pendientes, Grafo,
      Preguntar; que se pliegan al angostar la ventana.
- [ ] **Pendientes:** los filtros (Proyecto, Persona, Buscar, Origen) viven en la barra de la vista, no en la barra de
      herramientas de la ventana: desviación deliberada de §16.8. Verificar que se ven bien y persisten.
- [ ] Fichas: **⌘[** atrás, ficha filtrada al proyecto, "Ver todo →", "Ver en el grafo" enfocado.
- [ ] Preguntar: conversaciones sobreviven al reiniciar y al cambiar de cerebro; **Guardar como página** aparece en
      Contenido y ⌘K.
- [ ] Correo automático: una regla nueva guarda sola los correos entrantes y avisa.

## 4. Diferido de v0.5

- Oferta de regla en Correo: el dominio sigue en negritas y queda un comentario viejo sobre el contraste de `text2` (`RuleOfferBar.swift`).

- ~~Búsqueda de texto completo en ⌘K~~: hecho en 0.6.0.
- Animación D "conexión encontrada" (`docs/brand/05_motion/`).
- Exportes Rive / Lottie de las animaciones de marca.
- ~~Limpieza de strings sin uso en `Localizable.strings` (es/en)~~: hecho en 0.6.0.
- Caché de títulos de página en `VaultStore` (hoy los chips de origen resuelven títulos en cada carga).
- "Mis pendientes (n)" en Reuniones → Anteriores (si no quedó en 0.5.0).
- Conteo de coincidencias por regla en Ajustes → Reglas.
- Revisión de contraste restante: `text3` en texto informativo (no llega a AA; debería quedar solo en placeholders).
- Tests de UI (hoy: capturas + selftests de BrainCore).

## 5. GitHub: mejoras pequeñas (v0.4.0)

- `sb github status` no marca los repos cuyo proyecto ya no existe.
- "Abrir Ajustes" desde la hoja Repositorios… debe llevar a Ajustes → GitHub (verificar en vivo; ver §3).
- La CLI no tiene comando para cambiar las ramas seguidas (hoy: `sb github remove` + `add`, o "Elegir ramas" en la app).
- El Device Flow pide el scope `repo`, que da escritura (GitHub no ofrece uno de solo lectura para repos privados en
  OAuth Apps). La app solo hace GET; quien prefiera mínimo privilegio puede usar un token fine-grained de solo lectura.

## 6. Menores conocidos (v0.3.1)

- Outlook: los correos de "Elementos eliminados" no se filtran al importar un hilo.
- El `index.md` del vault template tiene una frase en inglés (viene de v0.1).
- ~~Con firma ad-hoc, los permisos (Llavero, micrófono, grabación) se perdían tras cada actualización~~: desde 0.5.3
  `build-app.sh --release` exige la identidad "SecondBrain Dev". No borrarla (ver CONTRACT §10).
