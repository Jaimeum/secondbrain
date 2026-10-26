# SecondBrain — Contrato entre módulos (v0.1)

Fuente de verdad para todas las piezas. Si algo aquí no alcanza, sigue el espíritu, documenta la
decisión al final de este archivo en "Decisiones durante el build" y NO cambies firmas públicas de
otro módulo.

Producto: app nativa macOS (SwiftUI) para gente NO técnica. Graba audio del sistema + micrófono,
transcribe local (WhisperKit + SpeakerKit en Neural Engine), y Claude (vía el CLI de Claude Code
del usuario, con su suscripción) mantiene un wiki markdown por proyecto al estilo "LLM Wiki" de
Karpathy (raw inmutable → wiki compilado; ops ingest/query/lint; index.md + log.md; esquema CLAUDE.md).
Todo local. Sin Docker. Sin git obligatorio. UI en español (default) e inglés, lenguaje humano.

## 1. Paquete Swift (`app/Package.swift`)

- swift-tools 6.0, `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v5]` (sin strict concurrency).
- Targets y dueños:

| Target | Tipo | Depende de | Dueño |
|---|---|---|---|
| `BrainCore` | library | Foundation, Security, PDFKit (solo Apple) | Agente C (código) / Agente D (`Resources/vault-template`) |
| `Recorder` | library | BrainCore, ScreenCaptureKit, AVFAudio | Agente A |
| `Transcription` | library | BrainCore, WhisperKit, SpeakerKit | Agente B |
| `SecondBrain` | executable (la app) | BrainCore, Recorder, Transcription, SwiftTerm | Agente E |
| `sb` | executable (CLI) | BrainCore, Transcription, ArgumentParser | Agente C |

- Recursos: `BrainCore` → `.copy("Resources/vault-template")`; `SecondBrain` → `.copy("Resources/web")`.
  Acceso SIEMPRE vía `Bundle.module`. El script de build copia los `.bundle` de SwiftPM a
  `SecondBrain.app/Contents/Resources/` (verificar que `Bundle.module` los encuentre en la .app).
- Bundle id: `app.secondbrain.mac`. Nombre visible: "SecondBrain".
- Compila solo con Command Line Tools (verificado: WhisperKit/SpeakerKit compilan y corren).

## 2. Rutas y configuración (BrainCore)

```swift
public struct AppConfig: Codable, Equatable, Sendable {
    public var vaultPath: String          // default "~/Documents/SecondBrain"
    public var dataPath: String           // default "~/Library/Application Support/SecondBrain/data"
    public var whisperModel: String       // default "large-v3"  (alternativa "large-v3-v20240930_turbo")
    public var claudePath: String?        // nil = autodetectar
    public var ingestModel: String        // default "sonnet"
    public var queryModel: String         // default "opus"
    public var uiLanguage: String         // "es" | "en", default "es"
    public var captureMic: Bool           // default true
    public var gitEnabled: Bool           // default false (si true y hay git, commit tras cada cambio)
    public var hotkeyEnabled: Bool        // default true (⌥⌘R)
    public var onboardingComplete: Bool   // default false
    public static let `default`: AppConfig
    public static var configURL: URL      // ~/Library/Application Support/SecondBrain/config.json
    public static func load() -> AppConfig            // default si no existe
    public func save() throws
    public var vaultURL: URL { get }      // expande ~
    public var dataURL: URL { get }
}

public struct DataPaths: Sendable {       // todo bajo dataURL
    public init(root: URL)
    public var sessions: URL   // data/sessions/<sessionId>/  (audio + session.json)
    public var sources: URL    // data/sources/<sourceId>.json
    public var jobs: URL       // data/jobs/<jobId>.json
    public var history: URL    // data/history/<historyId>/ (entry.json, before/, after/)
    public var models: URL     // data/models/  (downloadBase de WhisperKit/SpeakerKit)
    public var logs: URL       // data/logs/secondbrain.log
    public func ensureExist() throws
}
```
La instancia del autor usa vault=`~/secondbrain/vault`, data=`~/secondbrain/data`.

Variables de entorno de override (útiles para CLI/tests): `SB_CONFIG` (ruta a config.json alterna).

## 3. Grabación: `session.json` (Recorder escribe, BrainCore/Transcription leen)

Directorio: `data/sessions/<sessionId>/`. `sessionId` = `yyyyMMdd-HHmmss-xxxx` (xxxx 4 hex aleatorios).
También es el `sourceId` de la fuente tipo meeting.

```swift
public struct SessionManifest: Codable, Equatable, Sendable {   // definido en BrainCore
    public var id: String
    public var title: String?            // nil → BrainCore usa "Reunión HH:mm" / "Meeting HH:mm"
    public var projectSlug: String?      // nil = Sin asignar (va a _inbox)
    public var startedAt: Date
    public var endedAt: Date?            // nil mientras graba
    public var sampleRate: Int           // 16000
    public var chunkSeconds: Int         // 300
    public var tracks: [String: [String]] // "system": ["system_000.wav",...], "mic": ["mic_000.wav",...]
    public var micCaptured: Bool
    public static func load(from dir: URL) throws -> SessionManifest   // dir/session.json
    public func save(to dir: URL) throws                                 // escritura atómica
}
```
Reglas de audio (CRÍTICAS para alinear pistas):
- WAV PCM 16-bit LE, mono, 16 kHz.
- Cada pista es una línea de tiempo CONTINUA desde `startedAt`: el chunk k cubre exactamente
  [k*chunkSeconds, (k+1)*chunkSeconds) segundos (el último puede ser más corto). Si no llega audio
  (silencio, ScreenCaptureKit no entrega buffers), el Recorder RELLENA con ceros según el reloj
  (host time) para no desalinear. Ambas pistas tienen la misma duración total (±0.5 s).
- `session.json` se reescribe al iniciar, al cerrar cada chunk y al detener (crash-safe: un chunk
  a medias sigue siendo un WAV válido o se repara el header al recuperar).

## 4. Fuentes, jobs, historial (BrainCore, persistidos como JSON)

```swift
public enum SourceKind: String, Codable, Sendable { case meeting, document, note, url }
public enum SourceStatus: String, Codable, Sendable {
    case recording, queued, transcribing, needsProject, ingesting, done, failed
}
public struct SourceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: SourceKind
    public var title: String
    public var projectSlug: String?
    public var status: SourceStatus
    public var rawPath: String?          // relativo al vault, ej "projects/xfiles/raw/meetings/2026-10-26-1530-kickoff.md"
    public var historyId: String?        // cambio de ingesta
    public var suggestedProject: String? // de classify
    public var suggestionReason: String?
    public var error: String?
    public var progress: Double?         // 0...1 durante transcribing/ingesting
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: Double?  // meetings
}

public enum JobKind: String, Codable, Sendable { case transcribe, ingest, classify, lint, saveAnswer }
public enum JobStatus: String, Codable, Sendable { case queued, running, done, failed, cancelled }
public struct Job: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: JobKind
    public var status: JobStatus
    public var sourceId: String?
    public var projectSlug: String?
    public var payload: [String: String]  // ej saveAnswer: ["question":..., "answer":...]
    public var attempts: Int
    public var notBefore: Date?           // backoff (rate limit de Claude)
    public var error: String?
    public var message: String?           // texto humano de progreso
    public var progress: Double?
    public var historyId: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public enum ChangeType: String, Codable, Sendable { case added, modified, deleted }
public struct FileChange: Codable, Equatable, Sendable { public var path: String; public var change: ChangeType }
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String              // humano: "Aprendió de: Kickoff X-Files"
    public var kind: JobKind
    public var sourceId: String?
    public var projectSlug: String?
    public var changes: [FileChange]
    public var createdAt: Date
    public var undone: Bool
}
```
Cola: serial (1 job a la vez), persistente, al arrancar `running`→`queued`. Reintentos: hasta 3, con
backoff exponencial; si Claude reporta rate limit/usage limit → `notBefore` = +15 min (o el reset que
reporte) sin consumir intento. Transcribe y Claude-jobs pueden ir en la misma cola serial.

Pipeline:
1. `recordingStarted(m)` → SourceRecord(kind meeting, status recording).
2. `recordingFinished(m)` → status queued + Job transcribe.
3. transcribe → `Transcribing.transcribe` → BrainCore escribe el .md (TranscriptWriter, §6) en
   `projects/<p>/raw/meetings/` o `_inbox/meetings/` → SOLO si la escritura fue exitosa borra los WAV
   (deja session.json) → si hay proyecto: Job ingest; si no: status needsProject + Job classify.
4. ingest → HistoryStore.begin → Claude `/ingest` → HistoryStore.commit → source.done + historyId.
5. `assign(sourceId, project)` → mueve el raw de `_inbox/...` a `projects/<p>/raw/...`, actualiza
   frontmatter `project:` del raw (única excepción a la inmutabilidad), Job ingest.
6. imports: `importFile/importURL/addNote` copian/crean en `raw/docs|notes` (o `_inbox/...`) → ingest
   (o classify si no hay proyecto). PDFs se copian tal cual (Claude Read los lee). URL: se descarga y
   se convierte a texto (NSAttributedString HTML→texto) en `.md` con `source_url` en frontmatter.

## 5. Interfaces entre módulos

### 5.1 Transcription (implementa, BrainCore define)
```swift
// BrainCore
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double        // segundos desde startedAt de la sesión
    public var end: Double
    public var speaker: String      // "me" para mic; "S1","S2",... para sistema (orden de 1a aparición); "S?" si no se pudo
    public var track: String        // "mic" | "system"
    public var text: String
}
public struct Transcript: Codable, Equatable, Sendable {
    public var language: String?    // ISO 639-1 dominante, ej "es"
    public var durationSeconds: Double
    public var segments: [TranscriptSegment]   // ordenados por start, sin duplicados de eco
}
public struct ModelPrepProgress: Sendable { public var fraction: Double; public var message: String }
public protocol Transcribing: AnyObject, Sendable {
    /// Descarga (a DataPaths.models) y carga modelos. Idempotente. Progreso para onboarding.
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws
    var isReady: Bool { get }
    func transcribe(sessionDir: URL, manifest: SessionManifest,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript
}
```
`Transcription` expone `public final class WhisperTranscriber: Transcribing` con
`public init(modelName: String, modelsDir: URL)`. Detalles: concatenar chunks por pista, VAD chunking,
`wordTimestamps`, idioma auto-detectado POR SEGMENTO/ventana (las juntas mezclan es/en), SpeakerKit
solo en pista system, `addSpeakerInfo` para atribuir; mic → "me". Dedup de eco: descartar segmento
mic que se solape en tiempo con un segmento system y tenga similitud de texto ≥ 0.6 (normalizado).
Descartar alucinaciones típicas de whisper en silencio ("Gracias por ver", "Subtítulos por...",
"Thank you." repetidos) cuando el RMS del tramo es casi cero. Modelo: `openai_whisper-<modelName>` del
repo argmaxinc/whisperkit-coreml; descarga con `WhisperKit.download(variant:downloadBase:)`.

### 5.2 Recorder (Agente A)
```swift
@MainActor @Observable public final class Recorder {
    public enum State: Equatable { case idle, starting, recording(since: Date), stopping, failed(String) }
    public private(set) var state: State
    public private(set) var systemLevel: Float   // 0...1, para medidor
    public private(set) var micLevel: Float
    public private(set) var current: SessionManifest?
    public init(sessionsDir: URL)
    public func start(title: String?, projectSlug: String?, captureMic: Bool) async throws -> SessionManifest
    public func stop() async throws -> SessionManifest      // endedAt puesto y guardado
    public func updateCurrent(title: String?, projectSlug: String?)   // cambiar proyecto mientras graba
    public static func permissions() async -> RecorderPermissions
    public static func requestMicrophone() async -> Bool
    public static func requestScreenCapture() async -> Bool  // dispara el prompt de TCC (SCShareableContent)
    public static func openPrivacySettings(_ pane: PrivacyPane)  // abre Ajustes en el panel correcto
}
public struct RecorderPermissions: Equatable, Sendable { public var screenAudio: Bool; public var microphone: Bool }
public enum PrivacyPane: Sendable { case screenRecording, microphone }
```
Sistema: SCStream con `capturesAudio = true`, `excludesCurrentProcessAudio = true`, video mínimo
(2x2, 1 fps) y descartar frames de video. Mic: AVAudioEngine con `setVoiceProcessingEnabled(true)`
(AEC) y ducking mínimo; si falla VP, continuar sin AEC. Convertir a 16 kHz mono Int16 (AVAudioConverter).
`recoverInterruptedSessions(in:) -> [SessionManifest]`: estático; sesiones sin endedAt (crash) → reparar
headers WAV, poner endedAt, devolverlas para que la app las encole.

### 5.3 BrainCore façade (Agente C) — usada por la app y por `sb`
```swift
@MainActor @Observable public final class BrainEngine {
    public private(set) var config: AppConfig
    public let paths: DataPaths
    public let vault: VaultStore
    public let projects: ProjectManager
    public let history: HistoryStore
    public let claude: ClaudeRunner
    public private(set) var sources: [SourceRecord]   // orden: más reciente primero
    public private(set) var jobs: [Job]
    public private(set) var isProcessing: Bool
    public init(config: AppConfig, transcriber: Transcribing)
    public func start()                                // asegura dirs, instala vault-template si falta, reanuda cola
    public func updateConfig(_ c: AppConfig) throws
    public func recordingStarted(_ m: SessionManifest)
    public func recordingFinished(_ m: SessionManifest)
    public func importFile(_ url: URL, projectSlug: String?) throws
    public func importURL(_ url: URL, projectSlug: String?) async throws
    public func addNote(title: String, body: String, projectSlug: String?) throws
    public func assign(sourceId: String, to projectSlug: String) throws
    public func retry(sourceId: String)
    public func delete(sourceId: String) throws        // borra registro (+ audio si aún existe); NO borra raw ya ingestado
    public func ask(_ question: String, projectSlug: String?) -> AsyncThrowingStream<ClaudeEvent, Error>
    public func saveAnswer(question: String, answer: String, projectSlug: String?)
    public func lint(projectSlug: String?)
    public func undo(historyId: String) throws
    public func runUntilIdle() async                   // CLI/tests: procesa la cola hasta vacía
    public var onEvent: ((EngineEvent) -> Void)?       // notificaciones a la UI (job terminado, error, rate limit)
}
public enum EngineEvent: Sendable { case sourceUpdated(SourceRecord), jobFailed(Job), rateLimited(until: Date), historyAdded(HistoryEntry) }
```

### 5.4 ClaudeRunner (Agente C)
```swift
public enum ClaudeEvent: Sendable, Equatable {
    case text(String)                  // texto del asistente (incremental o por mensaje)
    case tool(name: String, detail: String)   // "Leyendo projects/x/wiki/index.md"
    case done(result: String, isError: Bool)
}
public enum ClaudeMode: Sendable { case readOnly, edit }  // readOnly: Read,Glob,Grep ; edit: + Write,Edit,MultiEdit
public final class ClaudeRunner: Sendable {
    public init(configProvider: @escaping @Sendable () -> AppConfig, vaultURL: URL)
    public func run(command: String, arguments: String, mode: ClaudeMode, model: String) -> AsyncThrowingStream<ClaudeEvent, Error>
    public func runPrompt(_ prompt: String, mode: ClaudeMode, model: String) -> AsyncThrowingStream<ClaudeEvent, Error>
}
public enum ClaudeError: Error { case notInstalled, notAuthenticated, rateLimited(resetAt: Date?), failed(String) }
public enum ClaudeSetup {   // onboarding
    public static func locate(config: AppConfig) -> URL?           // config.claudePath, ~/.local/bin/claude, /opt/homebrew/bin, /usr/local/bin, `zsh -lc 'command -v claude'`
    public static func install(log: @escaping @Sendable (String) -> Void) async throws -> URL  // curl -fsSL https://claude.ai/install.sh | bash
    public static func checkAuth(config: AppConfig) async -> Bool  // claude -p "Responde solo: ok" --model haiku, timeout 90s
    public static func saveToken(_ token: String) throws           // Keychain service "app.secondbrain.mac", account "claude-oauth-token"
    public static func loadToken() -> String?
    public static func extractToken(from terminalOutput: String) -> String?  // regex sk-ant-oat[0-9A-Za-z_-]+
}
```
Ejecución: `claude -p <prompt> --output-format stream-json --verbose --model <m> --permission-mode acceptEdits --allowedTools <lista> --disallowedTools Bash,WebFetch,WebSearch`,
`cwd = vault`, env heredado + `PATH` ampliado + `CLAUDE_CODE_OAUTH_TOKEN` si hay token en Keychain.
`run(command:)` NO depende de slash commands: lee `vault/.claude/commands/<command>.md`, quita
frontmatter, reemplaza `$ARGUMENTS` y lo manda como prompt. Detectar rate/usage limit en el stream o
stderr → `ClaudeError.rateLimited`.

### 5.5 HistoryStore (Agente C)
`begin(title:kind:sourceId:projectSlug:) -> HistorySnapshot` (hash SHA256 de todos los archivos del
vault excepto `.git`, `.obsidian`, `.DS_Store`) ; `commit(_ snapshot) throws -> HistoryEntry?` (diff;
guarda `before/` de modificados/borrados y `after/` de añadidos/modificados; nil si no hubo cambios);
`entries() -> [HistoryEntry]`; `diff(entryId, path) -> (before: String?, after: String?)`;
`undo(entryId) throws` (restaura before, borra added; si un archivo cambió después, lanza
`HistoryError.conflict(paths)` — la UI ofrece "deshacer de todos modos" vía `undo(entryId, force: true)`).
Si `config.gitEnabled` y el vault es repo git → `git add -A && git commit -m <title>` tras commit/undo.

### 5.6 VaultStore / ProjectManager (Agente C)
```swift
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var slug: String; public var name: String; public var description: String
    public var emoji: String; public var createdAt: Date
    public var id: String { slug }
}
// projects/<slug>/project.json
public final class ProjectManager { list() -> [Project]; create(name:description:emoji:) throws -> Project; update(_:) throws }
public struct WikiPage: Identifiable, Hashable, Sendable { public var path: String /*rel vault*/; public var title: String; public var id: String { path } }
public final class VaultStore {
    public init(root: URL)
    public func installTemplateIfNeeded() throws          // copia vault-template/vault/ si vault vacío o sin CLAUDE.md
    public func pages(projectSlug: String?) -> [WikiPage] // nil = global (index.md, people/, log.md)
    public func read(_ relPath: String) throws -> String
    public func resolveWikilink(_ target: String, from relPath: String) -> String?  // por nombre de archivo (sin .md, case-insensitive), primero mismo proyecto, luego global
    public func backlinks(to relPath: String) -> [WikiPage]
    public func url(for relPath: String) -> URL
}
```
`ProjectManager.create` copia `vault-template/project/` a `projects/<slug>/`, reemplaza `{{PROJECT_NAME}}`,
`{{PROJECT_SLUG}}`, `{{PROJECT_DESCRIPTION}}`, `{{DATE}}` en todos los .md, escribe project.json y añade
la línea al `index.md` global. slug: ascii minúsculas, guiones, sin acentos, único.

## 6. Formato de la transcripción (raw de meeting, BrainCore `TranscriptWriter`)

Nombre: `YYYY-MM-DD-HHmm-<slug-titulo>.md` (fecha local de startedAt; slug ≤ 50 chars).
```markdown
---
type: transcript
source_id: 20261026-153000-ab12
title: Kickoff X-Files
project: xfiles            # o null
date: 2026-10-26T15:30:00-06:00
duration: "00:42:10"
language: es
speakers: ["Yo", "Hablante 1", "Hablante 2"]   # en inglés: "Me", "Speaker 1"
---

# Kickoff X-Files

**[00:00:03] Yo:** Hola equipo…
**[00:00:10] Hablante 1:** …
```
Turnos consecutivos del mismo hablante con pausa < 2 s se juntan en un párrafo. Etiquetas según
`config.uiLanguage`. Raw de documentos/notas: frontmatter `type: document|note|url`, `source_id`,
`title`, `project`, `date`, (`source_url`, `original_file`).

## 7. Vault (Agente D) — `app/Sources/BrainCore/Resources/vault-template/`
```
vault-template/
  vault/                         # se copia a la raíz del vault la primera vez
    CLAUDE.md                    # ESQUEMA GLOBAL (ver abajo)
    .claude/commands/ingest.md query.md lint.md classify.md save-answer.md
    index.md  log.md  people/README.md  _inbox/meetings/ _inbox/docs/ _inbox/notes/ (con .gitkeep)
    projects/.gitkeep
  project/                       # se copia a projects/<slug>/
    CLAUDE.md  raw/meetings/ raw/docs/ raw/notes/ raw/assets/
    wiki/index.md wiki/log.md wiki/overview.md wiki/tasks.md wiki/meetings/ wiki/topics/ wiki/decisions/ wiki/questions/
```
Reglas que el esquema DEBE imponer: raw/ inmutable; idioma de cada página = idioma dominante de su
fuente; wikilinks `[[nombre-de-archivo]]`; frontmatter YAML (`type`, `project`, `date`, `sources`,
`people`, `status`, `updated`); toda afirmación cita su fuente raw (con timestamp en reuniones);
contradicciones con `> [!conflict]`; personas globales en `people/<nombre-apellido>.md` con alias,
rol, proyectos y voz por reunión ("Hablante 1 en [[2026-10-26-1530-kickoff]]"); en la página de la
reunión `speakers:` mapea etiquetas→personas cuando se infieren con confianza (si no, se dejan);
actualizar `wiki/index.md` del proyecto, `index.md` global si aplica, y append a `wiki/log.md` y
`log.md` con `## [YYYY-MM-DD] ingest | Título`; `tasks.md` consolidado con dueño/fecha/fuente;
`overview.md` = síntesis viva del proyecto. Comandos (cuerpo usa `$ARGUMENTS`):
- `ingest`: args = ruta raw relativa al vault. Leer CLAUDE.md global + del proyecto, wiki/index.md, la
  fuente; crear `wiki/meetings/<mismo-nombre>.md` (o `wiki/sources/...` para docs) con resumen,
  decisiones, pendientes, citas; actualizar 5-15 páginas relacionadas; final: 3-6 líneas de resumen
  humano de qué cambió (la app lo muestra).
- `query`: args = `scope=<slug|global> | <pregunta>`. Solo lectura. Empezar por index.md. Respuesta
  en el idioma de la pregunta, con citas como wikilinks `[[pagina]]`. No escribir archivos.
- `save-answer`: args = JSON `{"project":..., "question":..., "answer":...}` → crea
  `wiki/questions/<fecha>-<slug>.md`, enlaza desde index y páginas relevantes.
- `lint`: args = slug o `global`. Revisa contradicciones, huérfanas, links rotos, datos viejos,
  pendientes vencidos, conceptos sin página; arregla lo trivial; escribe `wiki/health.md`.
- `classify`: args = ruta raw en `_inbox`. Solo lectura. Lee `index.md` y `projects/*/project.json`/
  overviews. Responde SOLO una línea JSON: `{"project":"<slug>|null","confidence":0-1,"reason":"..."}`.

## 8. App (Agente E) — `app/Sources/SecondBrain/`
Estructura: `SecondBrainApp.swift` (@main; WindowGroup principal + MenuBarExtra(.window) + Settings),
`AppState` (@Observable @MainActor: crea BrainEngine con WhisperTranscriber, Recorder, enruta eventos),
vistas: Onboarding, Sidebar (Proyectos, Inbox con badge, Personas, + nuevo proyecto), ProjectView con
tabs Wiki / Reuniones y fuentes / Preguntar / Actividad, WikiView (WKWebView + markdown-it local en
`Resources/web/`, wikilinks → navegación interna, backlinks), ChatView (streaming ClaudeEvent, citas
clicables, "Guardar en el wiki"), ActivityView (HistoryEntry, diff lado a lado, "Deshacer cambios"),
MenuBarView (● Grabar / ■ Detener + temporizador + medidores, selector de proyecto, título, estado de
la cola), hotkey global ⌥⌘R (Carbon RegisterEventHotKey, sin permisos de accesibilidad), drag & drop
de archivos/URLs, notificaciones locales (UNUserNotificationCenter) al terminar "Listo: aprendí de …".
Onboarding (pasos, botones grandes, cero jerga): Bienvenida + aviso de consentimiento → Dónde guardar
(vault) → Permisos (abre Ajustes, re-chequea) → Claude (detectar; instalar con botón; "Conectar con
Claude" corre `claude setup-token` en SwiftTerm embebido, extrae y guarda token automáticamente;
verifica con checkAuth) → Descarga de modelos (barra de progreso; ~1.6 GB) → Primer proyecto → Listo.
Textos: `Localizable` es/en (helper `L("clave")`); vocabulario: "Aprendiendo de la reunión…",
"Transcribiendo…", "Revisar mi cerebro" (lint), "Deshacer cambios", "Sin asignar".
App normal (Dock) + menu bar; cerrar la ventana no cierra la app.
Info.plist: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `LSMinimumSystemVersion 15.0`.

## 9. CLI `sb` (Agente C) — para pruebas E2E y power users
`sb init [--vault P] [--data P]` · `sb project create "<nombre>" [--description ..]` · `sb projects`
· `sb simulate --system a.wav [--mic b.wav] [--project slug] [--title t]` (crea sesión partiendo/convirtiendo
a chunks 16k mono según §3 y llama recordingFinished) · `sb run` (runUntilIdle con logs) · `sb status`
· `sb import <file|url> [--project]` · `sb note "<título>" "<texto>" [--project]` · `sb assign <sourceId> <slug>`
· `sb ask "<pregunta>" [--project]` (imprime streaming) · `sb lint [--project]` · `sb history`
· `sb diff <historyId>` · `sb undo <historyId> [--force]` · `sb models prepare`.
Usa `SB_CONFIG` para no tocar la config real en tests.

## 10. Scripts (Agente A) — `scripts/`
`make-dev-cert.sh` (crea identidad self-signed "SecondBrain Dev" en el login keychain si no existe;
idempotente), `build-app.sh [--release]` (swift build -c release, ensambla `build/SecondBrain.app`,
Info.plist, icono simple generado (iconutil, opcional), copia bundles de recursos, firma con
"SecondBrain Dev" si existe o ad-hoc `-`, entitlements no-sandbox; `--release` además genera
`dist/SecondBrain-<ver>.zip` (ditto) y `dist/SecondBrain-<ver>.dmg` (hdiutil, con alias a /Applications)),
`release.sh <version>` (gh repo create si no existe, push, gh release create con zip+dmg).
Versión en `VERSION` (raíz), inicial `0.1.0`.

## Decisiones durante el build
(cada agente añade aquí, con su letra, cualquier decisión que afecte a otros)
- [Lead] Spike verificado (CLT, sin Xcode): WhisperKit `large-v3` + SpeakerKit transcriben y diarizan un
  audio mixto es/en correctamente (2 hablantes, X-Files bien escrito). API real usada:
  `WhisperKit(WhisperKitConfig(model: "large-v3"))`, `AudioProcessor.loadAudioAsFloatArray(fromPath:)`,
  `transcribe(audioArray:decodeOptions: DecodingOptions(wordTimestamps: true, chunkingStrategy: .vad))`,
  `SpeakerKit()`, `diarize(audioArray:)`, `diarization.addSpeakerInfo(to: transcription)` → grupos con
  `.speaker`, `.startTime`, `.endTime`, `.text`. Ojo: la detección de idioma reportó "en" para todo el
  audio aunque la mayoría era español → detectar idioma por segmento/ventana. Primera carga ~90 s
  (descarga + compilación ANE); se cachea.
- [Lead] Los archivos `_Skeleton.swift` de cada target son temporales: cada dueño los reemplaza.
  Compila tu target aislado: `cd app && swift build --target <Target> --scratch-path .build-<letra>`.
