# Pendientes

## 0. Registrar SecondBrain en GitHub (OAuth App con Device Flow)

Sin esto el botón "Conectar GitHub" por código de dispositivo no funciona; **"Usar mi sesión de GitHub CLI" y pegar un token siguen funcionando**.

1. https://github.com/settings/developers → **OAuth Apps** → **New OAuth App**.
2. Application name `SecondBrain`, Homepage URL `https://github.com/Jaimeum/secondbrain`, Authorization callback URL `http://127.0.0.1`.
3. **Register application**.
4. Marcar **Enable Device Flow** → **Update application**.
5. Copiar el **Client ID** (no hace falta el client secret).

Dónde va (no se mete en el código):

```bash
echo "<Client ID>" > ~/.config/secondbrain/github-client-id.txt
scripts/release.sh <versión>      # build-app.sh lo inyecta en oauth-defaults.json como githubClientId
```

Para probar sin compilar: `SB_GITHUB_CLIENT_ID=<id>`.

Nota para organizaciones: si la organización tiene la **Third-party access policy** (restricción de OAuth Apps), un owner debe aprobar SecondBrain en Settings → Third-party Access → OAuth app policy. Si usa SAML SSO, hay que **Authorize** el token/la app para esa organización.

## 1. Registrar SecondBrain en Microsoft (para "Conectar Microsoft 365")

Hoy el botón muestra "SecondBrain aún no está registrada en Microsoft 365" porque falta este trámite (10 min, gratis):

1. https://entra.microsoft.com → Identidad → Aplicaciones → **Registros de aplicaciones** → **Nuevo registro**.
2. Nombre `SecondBrain`. Tipos de cuenta: **"Cuentas en cualquier directorio organizativo (multiinquilino) y cuentas personales de Microsoft"**.
3. URI de redirección: plataforma **"Aplicaciones móviles y de escritorio"**, valor `http://localhost`. Registrar.
4. **Autenticación** → Configuración avanzada → "Permitir flujos de cliente público": **Sí** → Guardar.
5. **Permisos de API** → Agregar → Microsoft Graph → Permisos delegados: `User.Read`, `Mail.Read`, `Calendars.Read`, `offline_access`.
6. **Información general** → copiar el **Id. de aplicación (cliente)**.

Dónde va (no se mete en el código):

```bash
echo "<Id. de aplicación (cliente)>" > ~/.config/secondbrain/microsoft-client-id.txt
scripts/release.sh 0.3.2      # build-app.sh lo inyecta en SecondBrain.app/Contents/Resources/oauth-defaults.json
```

Para probar sin publicar: Ajustes → Cuentas → Avanzado, o `SB_MS_CLIENT_ID=<id>` al lanzar la app.

Opcional después: verificación de editor (Partner Center) para que menos organizaciones bloqueen la app por defecto.

## 2. Google: salir del modo "En pruebas"

El registro ya está hecho (archivo en `~/.config/secondbrain/google-client.json`, incluido desde 0.3.1). Mientras la app esté
"En pruebas", solo entran los correos agregados como usuarios de prueba (máx. 100) y Google muestra "app no verificada".

Cuando haya usuarios: Google Cloud → Google Auth Platform → **Centro de verificación** → enviar a verificación.
`calendar.readonly` solo pide la verificación normal; `gmail.readonly` es permiso restringido y pide además una
auditoría de seguridad externa (CASA, de pago). Alternativa si pesa: publicar solo con calendario y dejar Gmail para después.

## 3. Probar la v0.4.0

- Abrir la app y probar a mano la pestaña **Código**, Ajustes → GitHub (conectar con `gh`, token y Device Flow) y las **Reglas**.
  Hasta ahora solo se revisaron capturas con datos demo (`SB_DEMO_GITHUB=1`).
- Contra GitHub real (solo se probó `Jaimeum/secondbrain` con `main`): seguir dos ramas a la vez, force-push / rebase
  (rama "reescrita"), rama borrada ("ya no existe") y cambios en PRs e issues entre dos sincronizaciones.
  Hoy esos casos solo los cubre `sb github selftest` (sin red).

## 4. GitHub: mejoras pequeñas (v0.4.0)

- `sb github status` no marca los repos cuyo proyecto ya no existe.
- "Abrir Ajustes" desde la pestaña Código abre Ajustes pero no lleva a la sección GitHub.
- La CLI no tiene comando para cambiar las ramas seguidas (hoy: `sb github remove` + `add`, o "Elegir ramas" en la app).
- El Device Flow pide el scope `repo`, que da escritura (GitHub no ofrece uno de solo lectura para repos privados en
  OAuth Apps). La app solo hace GET; quien prefiera mínimo privilegio puede usar un token fine-grained de solo lectura.

## 5. Menores conocidos (v0.3.1)

- Outlook: los correos de "Elementos eliminados" no se filtran al importar un hilo.
- El `index.md` del vault template tiene una frase en inglés (viene de v0.1).
- Con firma ad-hoc (sin identidad "SecondBrain Dev"), el Llavero vuelve a pedir permiso tras cada actualización.
