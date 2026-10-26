# SecondBrain: acceso bloqueado por tu organización / Access blocked by your organization

---

# Microsoft 365 — Español (México)

## (A) Para ti

Copia y envía este mensaje a tu administrador de TI:

> Hola, quiero conectar la app SecondBrain a mi cuenta de Microsoft 365, pero la organización bloquea el consentimiento.
> ID de aplicación: {clientId}
> Permisos delegados que solicita: User.Read, Mail.Read, Calendars.Read, offline_access.
> Es solo lectura (no envía, edita ni borra nada) y mis datos se quedan en mi Mac.
> ¿Puedes aprobarla? Enlace de consentimiento: https://login.microsoftonline.com/common/adminconsent?client_id={clientId}

## (B) Para tu administrador

1. Inicia sesión como Administrador global o Administrador de aplicaciones en el Centro de administración de Microsoft Entra (entra.microsoft.com).
2. Abre este enlace: https://login.microsoftonline.com/common/adminconsent?client_id={clientId}
3. Revisa los permisos: User.Read, Mail.Read, Calendars.Read, offline_access (todos delegados, solo lectura).
4. Selecciona Aceptar para otorgar el consentimiento en nombre de la organización.
5. Verifica en Identidad → Aplicaciones → Aplicaciones empresariales → SecondBrain → Seguridad → Permisos.
6. Si prefieres revisar solicitudes: Identidad → Aplicaciones → Aplicaciones empresariales → Actividad → Solicitudes de consentimiento de administrador.
7. Si el usuario no puede ni solicitar: Aplicaciones empresariales → Consentimiento y permisos → Configuración del consentimiento del usuario, y permite las solicitudes de consentimiento de administrador.

## (C) Usar tu propio registro de aplicación

1. Entra al Centro de administración de Microsoft Entra → Identidad → Aplicaciones → Registros de aplicaciones.
2. Selecciona Nuevo registro.
3. Nombre: SecondBrain.
4. Tipos de cuenta compatibles: cuentas en cualquier directorio organizativo (multiinquilino) y cuentas Microsoft personales.
5. URI de redirección: plataforma Cliente público o nativo (móvil y escritorio), valor http://localhost.
6. Selecciona Registrar.
7. Ve a Autenticación y activa Permitir flujos de cliente público: Sí.
8. Ve a Permisos de API → Agregar un permiso → Microsoft Graph → Permisos delegados.
9. Agrega User.Read, Mail.Read, Calendars.Read y offline_access.
10. En Información general, copia el Id. de aplicación (cliente) y pégalo en SecondBrain.

---

# Microsoft 365 — English

## (A) For you

Copy and send this message to your IT admin:

> Hi, I want to connect the SecondBrain app to my Microsoft 365 account, but our organization blocks consent.
> Application ID: {clientId}
> Delegated permissions requested: User.Read, Mail.Read, Calendars.Read, offline_access.
> It is read-only (it never sends, edits or deletes anything) and my data stays on my Mac.
> Could you approve it? Consent link: https://login.microsoftonline.com/common/adminconsent?client_id={clientId}

## (B) For your administrator

1. Sign in as Global Administrator or Application Administrator at the Microsoft Entra admin center (entra.microsoft.com).
2. Open this link: https://login.microsoftonline.com/common/adminconsent?client_id={clientId}
3. Review the permissions: User.Read, Mail.Read, Calendars.Read, offline_access (all delegated, read-only).
4. Select Accept to grant consent on behalf of your organization.
5. Verify under Identity → Applications → Enterprise applications → SecondBrain → Security → Permissions.
6. To review requests instead: Identity → Applications → Enterprise applications → Activity → Admin consent requests.
7. If users cannot even request access: Enterprise applications → Consent and permissions → User consent settings, and allow admin consent requests.

## (C) Use your own app registration

1. Go to Microsoft Entra admin center → Identity → Applications → App registrations.
2. Select New registration.
3. Name: SecondBrain.
4. Supported account types: Accounts in any organizational directory (Multitenant) and personal Microsoft accounts.
5. Redirect URI: platform Public client/native (mobile & desktop), value http://localhost.
6. Select Register.
7. Go to Authentication and set Allow public client flows to Yes.
8. Go to API permissions → Add a permission → Microsoft Graph → Delegated permissions.
9. Add User.Read, Mail.Read, Calendars.Read and offline_access.
10. On Overview, copy the Application (client) ID and paste it into SecondBrain.

---

# Google (Gmail y Calendar) — Español (México)

## (A) Para ti

Copia y envía este mensaje a tu administrador de Google Workspace:

> Hola, quiero conectar la app SecondBrain a mi cuenta de Google, pero la organización bloquea el acceso.
> ID de cliente: {clientId}
> Permisos que solicita: gmail.readonly, calendar.readonly, openid email profile.
> Es solo lectura (no envía, edita ni borra nada) y mis datos se quedan en mi Mac.
> ¿Puedes marcarla como app de confianza en la Consola de administración?

## (B) Para tu administrador

1. Inicia sesión en la Consola de administración de Google (admin.google.com) como superadministrador.
2. Ve a Seguridad → Controles de acceso y de datos → Controles de la API.
3. Selecciona Administrar el acceso de apps de terceros.
4. Selecciona Configurar nueva app (Add app) → Nombre de la app de OAuth o ID de cliente (OAuth App Name Or Client ID).
5. Pega {clientId} y selecciona Buscar.
6. Elige la app y selecciona el ID de cliente correspondiente.
7. Elige las unidades organizativas o grupos que tendrán acceso.
8. Selecciona Acceso: De confianza (Trusted): puede acceder a todos los servicios de Google.
9. Confirma con Finalizar.
10. Revisa que Gmail y Calendar no estén restringidos en Controles de la API → Configuración.

## (C) Usar tu propio registro de aplicación

1. Entra a console.cloud.google.com y crea un proyecto nuevo llamado SecondBrain.
2. Ve a APIs y servicios → Biblioteca y habilita Gmail API y Google Calendar API.
3. Ve a Plataforma de autenticación de Google (Pantalla de consentimiento de OAuth) y selecciona Comenzar.
4. Tipo de usuario: Interno si usas Workspace; Externo si usas Gmail personal.
5. Si es Externo, en Público agrega tu correo como usuario de prueba.
6. En Acceso a los datos, agrega los permisos: gmail.readonly, calendar.readonly, openid, email, profile.
7. Ve a Credenciales → Crear credenciales → ID de cliente de OAuth.
8. Tipo de aplicación: App de escritorio. Nombre: SecondBrain.
9. Selecciona Crear.
10. Copia el ID de cliente y el secreto de cliente y pégalos en SecondBrain.

---

# Google (Gmail and Calendar) — English

## (A) For you

Copy and send this message to your Google Workspace admin:

> Hi, I want to connect the SecondBrain app to my Google account, but our organization blocks access.
> Client ID: {clientId}
> Permissions requested: gmail.readonly, calendar.readonly, openid email profile.
> It is read-only (it never sends, edits or deletes anything) and my data stays on my Mac.
> Could you mark it as a trusted app in the Admin console?

## (B) For your administrator

1. Sign in to the Google Admin console (admin.google.com) as a super admin.
2. Go to Security → Access and data control → API controls.
3. Select Manage Third-Party App Access.
4. Select Add app → OAuth App Name Or Client ID.
5. Paste {clientId} and select Search.
6. Choose the app and select its matching client ID.
7. Choose the organizational units or groups that get access.
8. Set access to Trusted: Can access all Google services.
9. Confirm with Finish.
10. Check that Gmail and Calendar are not restricted under API controls → Settings.

## (C) Use your own app registration

1. Go to console.cloud.google.com and create a new project named SecondBrain.
2. Go to APIs & Services → Library and enable Gmail API and Google Calendar API.
3. Go to Google Auth Platform (OAuth consent screen) and select Get started.
4. User type: Internal if you use Workspace; External if you use personal Gmail.
5. If External, under Audience add your email as a test user.
6. Under Data Access, add the scopes: gmail.readonly, calendar.readonly, openid, email, profile.
7. Go to Credentials → Create credentials → OAuth client ID.
8. Application type: Desktop app. Name: SecondBrain.
9. Select Create.
10. Copy the client ID and client secret and paste them into SecondBrain.
