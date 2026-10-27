# Pendientes

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

## 3. Menores conocidos (v0.3.1)

- Outlook: los correos de "Elementos eliminados" no se filtran al importar un hilo.
- El `index.md` del vault template tiene una frase en inglés (viene de v0.1).
- Con firma ad-hoc (sin identidad "SecondBrain Dev"), el Llavero vuelve a pedir permiso tras cada actualización.
