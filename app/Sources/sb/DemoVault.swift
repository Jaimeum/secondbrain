import ArgumentParser
import BrainCore
import Foundation

/// `sb demo-vault --dir <vault>`: a realistic sample brain (3 projects, ~55 wiki pages, 12 people, tasks, timelines,
/// raw transcripts and emails) richly wikilinked, with event dates spanning the last 3 months, plus two routing rules.
/// Used to review the graph (and every other screen) without recording anything. `--scale N` adds N synthetic meetings per project
/// (plus topics and people) to test the graph with thousands of nodes.
struct DemoVaultCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo-vault", abstract: "Create a sample vault to try SecondBrain.")
    @Option(help: "Vault folder to create (must be empty or not exist)") var dir: String
    @Option(help: "Extra synthetic meetings per project (stress test)") var scale: Int = 0
    @Flag(help: "Delete the folder first if it exists") var force = false

    @MainActor func run() async throws {
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            if !contents.filter({ $0 != ".DS_Store" }).isEmpty {
                guard force else { throw CLIError("\(root.path) is not empty (use --force to replace it)") }
                try fm.removeItem(at: root)
            }
        }
        let summary = try DemoVault.create(at: root, scale: scale)
        print(summary)
        print("Try it: sb graph --dir \(root.path)")
    }
}

/// `sb graph --dir <vault> [--project slug] [--json]`: node/edge counts of the knowledge graph (CONTRACT §12.2).
struct GraphCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "graph", abstract: "Show the knowledge graph of a vault.")
    @Option(help: "Vault folder (default: the configured vault)") var dir: String?
    @Option(help: "Only this project") var project: String?
    @Flag(help: "Print the whole graph as JSON") var json = false

    @MainActor func run() async throws {
        let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppConfig.load().vaultURL
        let start = Date()
        let graph = KnowledgeGraphBuilder.build(vaultRoot: root, projectSlug: project)
        let elapsed = Date().timeIntervalSince(start)
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            print(String(decoding: try enc.encode(graph), as: UTF8.self))
            return
        }
        print("\(graph.nodes.count) nodes, \(graph.edges.count) edges (\(String(format: "%.2f", elapsed)) s)")
        let kinds = Dictionary(grouping: graph.nodes, by: \.kind.rawValue).mapValues(\.count).sorted { $0.key < $1.key }
        print("kinds: " + kinds.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        let dated = graph.nodes.filter { $0.date != nil }.count
        print("dated: \(dated)")
        for hub in graph.nodes where hub.kind == .project { print("hub \(hub.id) «\(hub.title)» links=\(hub.links)") }
        let top = graph.nodes.filter { $0.kind != .project }.sorted { $0.links > $1.links }.prefix(8)
        print("most connected: " + top.map { "\($0.title) (\($0.links))" }.joined(separator: ", "))
    }
}

enum DemoVault {
    // MARK: Data

    struct Person { let key, name, role, org: String; let projects: [String]; let aliases: [String] }

    /// Global companies (§16.4, CLAUDE.md §8.11): people of these carry `org: "[[<key>]]"`, so Empresas shows in ⌘K,
    /// the global index and the fichas.
    struct Org { let key, name, kind, summary: String; let projects: [String]; let aliases: [String] }

    static let orgs: [Org] = [
        Org(key: "acme", name: "Acme", kind: "client", summary: "Cliente de Atlas: opera la red logística que usará el lanzamiento.",
            projects: ["lanzamiento-atlas"], aliases: ["Acme S.A.", "acme.com", "Acme Logistics"]),
        Org(key: "banco-nubia", name: "Banco Nubia", kind: "partner", summary: "Socio de la alianza de pagos; firma el convenio con Dive.",
            projects: ["alianza-banco-nubia"], aliases: ["Nubia", "nubia.bank"]),
        Org(key: "dive", name: "Dive", kind: "own", summary: "La empresa de Jaime (yo): producto, ingeniería y finanzas.",
            projects: ["lanzamiento-atlas", "migracion-a-la-nube", "alianza-banco-nubia"], aliases: ["dive.ai"]),
    ]

    static func orgKey(_ name: String) -> String? { orgs.first { $0.name == name }?.key }

    static let people: [Person] = [
        Person(key: "jaime-ruiz", name: "Jaime Ruiz", role: "Director de producto", org: "Dive", projects: ["lanzamiento-atlas", "migracion-a-la-nube", "alianza-banco-nubia"], aliases: ["Jaime", "Yo"]),
        Person(key: "ana-garcia", name: "Ana García", role: "Product manager", org: "Acme", projects: ["lanzamiento-atlas"], aliases: ["Ana", "ana@acme.com"]),
        Person(key: "luis-torres", name: "Luis Torres", role: "Líder técnico", org: "Dive", projects: ["lanzamiento-atlas", "migracion-a-la-nube"], aliases: ["Luis"]),
        Person(key: "sofia-mendez", name: "Sofía Méndez", role: "Diseñadora de producto", org: "Dive", projects: ["lanzamiento-atlas"], aliases: ["Sofía"]),
        Person(key: "carlos-vega", name: "Carlos Vega", role: "Director financiero", org: "Dive", projects: ["lanzamiento-atlas", "migracion-a-la-nube", "alianza-banco-nubia"], aliases: ["Carlos"]),
        Person(key: "marta-rios", name: "Marta Ríos", role: "Directora de alianzas", org: "Banco Nubia", projects: ["alianza-banco-nubia"], aliases: ["Marta", "marta.rios@nubia.bank"]),
        Person(key: "diego-paredes", name: "Diego Paredes", role: "Ingeniero de infraestructura", org: "Dive", projects: ["migracion-a-la-nube"], aliases: ["Diego"]),
        Person(key: "elena-castro", name: "Elena Castro", role: "Abogada", org: "Dive", projects: ["lanzamiento-atlas", "alianza-banco-nubia"], aliases: ["Elena"]),
        Person(key: "pablo-nunez", name: "Pablo Núñez", role: "Responsable de calidad", org: "Dive", projects: ["lanzamiento-atlas"], aliases: ["Pablo"]),
        Person(key: "lucia-romero", name: "Lucía Romero", role: "Marketing", org: "Dive", projects: ["lanzamiento-atlas", "alianza-banco-nubia"], aliases: ["Lucía"]),
        Person(key: "andres-silva", name: "Andrés Silva", role: "CTO", org: "Banco Nubia", projects: ["alianza-banco-nubia"], aliases: ["Andrés"]),
        Person(key: "valeria-ortiz", name: "Valeria Ortiz", role: "Operaciones", org: "Dive", projects: ["migracion-a-la-nube"], aliases: ["Valeria"]),
    ]

    enum Kind: String { case meeting, email, document, note, url, topic, decision, question }

    /// One wiki page. `daysAgo` = event date; `[[@key]]` / `[[@key|Label]]` in texts link another page of the
    /// sample by key (its file name depends on the date).
    struct Doc {
        let key: String
        let kind: Kind
        let title: String
        var daysAgo: Int? = nil
        var hour: Int = 10
        var people: [String] = []
        var summary: String
        var points: [String] = []
        var related: [String] = []
    }

    struct ProjectSpec {
        let name, emoji, description: String
        let docs: [Doc]
        let tasks: [(text: String, owner: String?, dueDaysAgo: Int?, doneDaysAgo: Int?, source: String)]
        let milestones: [(daysAgo: Int, text: String)]
        let state: String
    }

    // swiftlint:disable line_length
    static let projects: [ProjectSpec] = [
        ProjectSpec(
            name: "Lanzamiento Atlas", emoji: "🚀", description: "Lanzar la app Atlas con Acme antes de fin de año",
            docs: [
                Doc(key: "kickoff", kind: .meeting, title: "Kickoff de Atlas con Acme", daysAgo: 88, hour: 9,
                    people: ["jaime-ruiz", "ana-garcia", "luis-torres", "sofia-mendez"],
                    summary: "Arranque del proyecto con [[ana-garcia|Ana]]: alcance de la app, equipo y una primera fecha de lanzamiento.",
                    points: ["**Alcance** — app móvil para clientes de Acme, ver [[app-movil-atlas]]", "**Fecha** — se propone lanzar el 1 de diciembre → [[@dec-lanzar-1-dic]]", "**Plan** — [[plan-de-lanzamiento]] en tres fases", "[[sofia-mendez|Sofía]] propone rehacer el [[diseno-onboarding|onboarding]]"]),
                Doc(key: "propuesta", kind: .document, title: "Propuesta comercial Atlas v2", daysAgo: 85,
                    people: ["ana-garcia", "carlos-vega"],
                    summary: "La propuesta que firmó Acme: alcance, precio y calendario de entregas.",
                    points: ["Precio cerrado con tres pagos ligados a hitos", "Calendario alineado con el [[plan-de-lanzamiento]]", "Revisada por [[carlos-vega|Carlos]]"]),
                Doc(key: "contrato", kind: .email, title: "Contrato con Acme", daysAgo: 80, hour: 11,
                    people: ["ana-garcia", "elena-castro", "jaime-ruiz"],
                    summary: "✉️ Hilo con [[ana-garcia|Ana]] y [[elena-castro|Elena]] para cerrar el contrato de Atlas.",
                    points: ["Ana envía el contrato basado en la [[@propuesta|propuesta v2]]", "Elena pide cambiar la cláusula de datos personales", "Firmado sin más cambios"]),
                Doc(key: "dec-lanzar-1-dic", kind: .decision, title: "Lanzar Atlas el 1 de diciembre", daysAgo: 88,
                    people: ["jaime-ruiz", "ana-garcia"],
                    summary: "Primera fecha acordada en el [[@kickoff|kickoff]]. Reemplazada después por [[@dec-posponer]].",
                    points: ["Estado: reemplazada", "Motivo original: llegar antes de la temporada alta de Acme"]),
                Doc(key: "revision-diseno", kind: .meeting, title: "Revisión de diseño del onboarding", daysAgo: 74, hour: 16,
                    people: ["jaime-ruiz", "sofia-mendez", "ana-garcia"],
                    summary: "[[sofia-mendez|Sofía]] mostró el nuevo [[diseno-onboarding|onboarding]]; se acordó reducirlo a tres pasos.",
                    points: ["Tres pantallas en vez de siete → [[@dec-onboarding]]", "Ana pide probarlo con usuarios reales en las [[pruebas-beta]]"]),
                Doc(key: "dec-onboarding", kind: .decision, title: "Onboarding en tres pasos", daysAgo: 74,
                    people: ["sofia-mendez", "ana-garcia"],
                    summary: "Se acordó un onboarding de tres pasos para la [[app-movil-atlas|app]].",
                    points: ["Alternativa descartada: registro con siete pasos", "Consecuencia: menos campos obligatorios"]),
                Doc(key: "sprint3", kind: .meeting, title: "Planeación del sprint 3", daysAgo: 60, hour: 10,
                    people: ["jaime-ruiz", "luis-torres", "pablo-nunez"],
                    summary: "[[luis-torres|Luis]] y [[pablo-nunez|Pablo]] planearon el sprint que prepara la beta cerrada.",
                    points: ["Pagos dentro de la app: depende de la [[integracion-de-pagos]] con Nubia", "Pablo arma el plan de [[pruebas-beta]]", "Riesgo: la [[base-de-datos-clientes]] aún no está en la nube"]),
                Doc(key: "presupuesto-mkt", kind: .meeting, title: "Presupuesto de marketing", daysAgo: 45, hour: 12,
                    people: ["jaime-ruiz", "lucia-romero", "carlos-vega"],
                    summary: "[[lucia-romero|Lucía]] presentó la [[campana-lanzamiento|campaña]]; [[carlos-vega|Carlos]] pidió recortar un 20 %.",
                    points: ["Campaña en dos olas: prensa y redes", "Nadie sabe aún quién aprueba el gasto → [[quien-aprueba-presupuesto-marketing]]"]),
                Doc(key: "quien-aprueba-presupuesto-marketing", kind: .question, title: "¿Quién aprueba el presupuesto de marketing?", daysAgo: 45,
                    people: ["carlos-vega", "lucia-romero"],
                    summary: "Pregunta abierta desde la reunión de [[@presupuesto-mkt|presupuesto]].",
                    points: ["Carlos cree que lo aprueba el comité de dirección", "Lucía necesita la respuesta antes de contratar la agencia"]),
                Doc(key: "demo-acme", kind: .meeting, title: "Demo de Atlas a Acme", daysAgo: 30, hour: 15,
                    people: ["jaime-ruiz", "ana-garcia", "luis-torres", "sofia-mendez"],
                    summary: "Demo de la beta a Acme. Gustó el [[diseno-onboarding|onboarding]]; preocupan los tiempos de carga.",
                    points: ["Ana quiere ver datos reales de las [[pruebas-beta]]", "Luis promete mejorar el rendimiento antes del go / no-go"]),
                Doc(key: "resultados-beta", kind: .email, title: "Resultados de la beta cerrada", daysAgo: 20, hour: 9,
                    people: ["pablo-nunez", "luis-torres", "jaime-ruiz"],
                    summary: "✉️ [[pablo-nunez|Pablo]] comparte los resultados de las [[pruebas-beta]]: 4,6 de 5 y dos errores graves.",
                    points: ["Error en pagos con tarjetas de Nubia (ver [[integracion-de-pagos]])", "Luis estima una semana para corregirlo"]),
                Doc(key: "notas-beta", kind: .note, title: "Notas de la beta cerrada", daysAgo: 18,
                    people: ["pablo-nunez"],
                    summary: "Notas rápidas de las entrevistas con usuarios de la beta.",
                    points: ["Les encanta el [[diseno-onboarding|registro rápido]]", "Piden modo oscuro"]),
                Doc(key: "go-no-go", kind: .meeting, title: "Revisión go / no-go", daysAgo: 6, hour: 17,
                    people: ["jaime-ruiz", "ana-garcia", "luis-torres", "pablo-nunez", "lucia-romero"],
                    summary: "Con los errores de la beta aún abiertos, se decidió mover el lanzamiento al 12 de diciembre.",
                    points: ["Nueva fecha → [[@dec-posponer]]", "La [[campana-lanzamiento|campaña]] se mueve una semana", "[[ana-garcia|Ana]] lo comunica a Acme"]),
                Doc(key: "dec-posponer", kind: .decision, title: "Posponer el lanzamiento al 12 de diciembre", daysAgo: 6,
                    people: ["jaime-ruiz", "ana-garcia", "luis-torres"],
                    summary: "Reemplaza a [[@dec-lanzar-1-dic]]: dos semanas más para cerrar los errores de la beta.",
                    points: ["Decidido en la [[@go-no-go|revisión go / no-go]]", "Consecuencia: el [[plan-de-lanzamiento]] se ajusta"]),
                Doc(key: "plan-de-lanzamiento", kind: .topic, title: "Plan de lanzamiento",
                    people: ["jaime-ruiz", "ana-garcia", "lucia-romero"],
                    summary: "Tres fases: beta cerrada, lanzamiento con Acme y campaña abierta. Fecha actual: 12 de diciembre.",
                    points: ["Fase 1 — [[pruebas-beta]]", "Fase 2 — lanzamiento con Acme ([[@dec-posponer]])", "Fase 3 — [[campana-lanzamiento]]"]),
                Doc(key: "app-movil-atlas", kind: .topic, title: "App móvil Atlas",
                    people: ["luis-torres", "sofia-mendez"],
                    summary: "La app para clientes de Acme: cuentas, pagos y notificaciones.",
                    points: ["Onboarding: [[diseno-onboarding]]", "Pagos: [[integracion-de-pagos]]", "Infraestructura: [[@migracion-por-fases|migración a la nube]]"]),
                Doc(key: "diseno-onboarding", kind: .topic, title: "Diseño del onboarding",
                    people: ["sofia-mendez"],
                    summary: "Registro en tres pasos, validado en la beta.",
                    points: ["Decisión: [[@dec-onboarding]]", "Resultados: [[@notas-beta]]"]),
                Doc(key: "pruebas-beta", kind: .topic, title: "Pruebas beta",
                    people: ["pablo-nunez", "luis-torres"],
                    summary: "Beta cerrada con 120 usuarios de Acme durante tres semanas.",
                    points: ["Resultados: [[@resultados-beta]]", "Notas: [[@notas-beta]]"]),
                Doc(key: "campana-lanzamiento", kind: .topic, title: "Campaña de lanzamiento",
                    people: ["lucia-romero", "carlos-vega"],
                    summary: "Prensa y redes en dos olas, con un presupuesto aún por aprobar.",
                    points: ["Presupuesto: [[quien-aprueba-presupuesto-marketing]]", "Co-marketing con Nubia: [[modelo-de-comisiones]]"]),
            ],
            tasks: [
                ("Enviar a Acme el plan con la nueva fecha", "jaime-ruiz", -2, nil, "go-no-go"),
                ("Corregir el error de pagos con tarjetas Nubia", "luis-torres", -5, nil, "resultados-beta"),
                ("Confirmar quién aprueba el presupuesto de marketing", "carlos-vega", 10, nil, "presupuesto-mkt"),
                ("Mover la campaña una semana", "lucia-romero", -4, nil, "go-no-go"),
                ("Probar el onboarding con usuarios reales", "sofia-mendez", 40, 32, "revision-diseno"),
                ("Firmar el contrato con Acme", "jaime-ruiz", 75, 72, "contrato"),
                ("Preparar el plan de pruebas beta", "pablo-nunez", 50, 48, "sprint3"),
            ],
            milestones: [(-47, "Lanzamiento de Atlas (planeado)")],
            state: "La beta cerró con buena nota pero con dos errores graves; el lanzamiento se movió al 12 de diciembre."
        ),
        ProjectSpec(
            name: "Migración a la nube", emoji: "☁️", description: "Sacar los sistemas del centro de datos antes de marzo",
            docs: [
                Doc(key: "arranque", kind: .meeting, title: "Arranque de la migración", daysAgo: 82, hour: 9,
                    people: ["jaime-ruiz", "luis-torres", "diego-paredes", "valeria-ortiz"],
                    summary: "Objetivo: salir del centro de datos antes de marzo sin cortar el servicio.",
                    points: ["[[diego-paredes|Diego]] hará el [[@inventario-doc|inventario de sistemas]]", "Primeras dudas sobre [[costos-nube]]", "[[seguridad-y-accesos]] desde el día uno"]),
                Doc(key: "inventario-doc", kind: .document, title: "Inventario de sistemas", daysAgo: 67,
                    people: ["diego-paredes"],
                    summary: "Lista de 46 servidores y 12 bases de datos, con dueño y criticidad.",
                    points: ["La [[base-de-datos-clientes]] es la más crítica", "Ocho servidores se pueden apagar"]),
                Doc(key: "inventario-reunion", kind: .meeting, title: "Revisión del inventario", daysAgo: 68, hour: 11,
                    people: ["jaime-ruiz", "diego-paredes", "valeria-ortiz"],
                    summary: "Se revisó el [[@inventario-doc|inventario]] y se acordó migrar por fases.",
                    points: ["Decisión: [[@migracion-por-fases]]", "[[valeria-ortiz|Valeria]] define las ventanas de mantenimiento"]),
                Doc(key: "migracion-por-fases", kind: .decision, title: "Migrar por fases", daysAgo: 68,
                    people: ["jaime-ruiz", "diego-paredes"],
                    summary: "Tres fases: sistemas internos, servicios de clientes y la [[base-de-datos-clientes]] al final.",
                    points: ["Alternativa descartada: migración en un solo fin de semana", "Consecuencia: el proyecto termina en marzo"]),
                Doc(key: "cotizacion", kind: .email, title: "Cotización del proveedor de nube", daysAgo: 66, hour: 14,
                    people: ["carlos-vega", "diego-paredes", "jaime-ruiz"],
                    summary: "✉️ Dos proveedores enviaron su cotización; [[carlos-vega|Carlos]] pide comparar a tres años.",
                    points: ["Diferencia de un 18 % en [[costos-nube|costos]]", "Ambos cumplen los requisitos de [[seguridad-y-accesos]]"]),
                Doc(key: "revision-costos", kind: .meeting, title: "Revisión de costos", daysAgo: 50, hour: 13,
                    people: ["jaime-ruiz", "carlos-vega", "diego-paredes"],
                    summary: "Con la comparación a tres años se eligió el proveedor principal.",
                    points: ["Decisión: [[@dec-proveedor]]", "Ahorro estimado del 22 % frente al centro de datos ([[costos-nube]])"]),
                Doc(key: "dec-proveedor", kind: .decision, title: "Elegir el proveedor principal", daysAgo: 50,
                    people: ["carlos-vega", "jaime-ruiz"],
                    summary: "Proveedor A, con contrato de tres años y descuento por volumen.",
                    points: ["Basado en la [[@cotizacion|cotización]]", "Revisión anual de [[costos-nube]]"]),
                Doc(key: "plan-corte", kind: .note, title: "Plan de corte", daysAgo: 24,
                    people: ["valeria-ortiz", "diego-paredes"],
                    summary: "Pasos para el corte de la fase 2 y cómo volver atrás si algo falla.",
                    points: ["Corte en la madrugada del domingo", "Prueba de vuelta atrás en el [[@simulacro|simulacro]]"]),
                Doc(key: "simulacro", kind: .meeting, title: "Simulacro de corte", daysAgo: 25, hour: 8,
                    people: ["diego-paredes", "valeria-ortiz", "luis-torres"],
                    summary: "El simulacro funcionó en 3 h 40 min; falta resolver los respaldos históricos.",
                    points: ["Pregunta abierta: [[respaldo-de-datos-historicos]]", "La app [[app-movil-atlas|Atlas]] siguió funcionando durante el corte"]),
                Doc(key: "respaldo-de-datos-historicos", kind: .question, title: "¿Qué hacemos con los respaldos históricos?", daysAgo: 25,
                    people: ["diego-paredes", "elena-castro"],
                    summary: "Hay 9 años de respaldos; no está claro cuántos hay que conservar por ley.",
                    points: ["Elena revisa la obligación legal", "Relacionado: [[cumplimiento-regulatorio]]"]),
                Doc(key: "ventana", kind: .email, title: "Ventana de mantenimiento de noviembre", daysAgo: 12, hour: 18,
                    people: ["valeria-ortiz", "jaime-ruiz"],
                    summary: "✉️ [[valeria-ortiz|Valeria]] propone la ventana para migrar la [[base-de-datos-clientes]].",
                    points: ["Fecha propuesta: segundo domingo de noviembre", "Hay que avisar a Acme por el [[plan-de-lanzamiento]]"]),
                Doc(key: "seguimiento", kind: .meeting, title: "Seguimiento semanal de la migración", daysAgo: 3, hour: 10,
                    people: ["jaime-ruiz", "diego-paredes", "valeria-ortiz", "luis-torres"],
                    summary: "Fase 1 terminada. La fase 2 empieza tras el lanzamiento de Atlas.",
                    points: ["Se confirma la ventana: [[@ventana]]", "[[costos-nube|Costos]] dentro del presupuesto"]),
                Doc(key: "costos-nube", kind: .topic, title: "Costos de nube",
                    people: ["carlos-vega", "diego-paredes"],
                    summary: "Presupuesto anual y comparación con el centro de datos.",
                    points: ["Cotización: [[@cotizacion]]", "Decisión: [[@dec-proveedor]]"]),
                Doc(key: "base-de-datos-clientes", kind: .topic, title: "Base de datos de clientes",
                    people: ["diego-paredes", "luis-torres"],
                    summary: "La pieza más crítica: la usan Atlas y la integración con Nubia.",
                    points: ["Se migra en la fase 3 ([[@migracion-por-fases]])", "La usa [[integracion-de-pagos]]"]),
                Doc(key: "seguridad-y-accesos", kind: .topic, title: "Seguridad y accesos",
                    people: ["diego-paredes", "elena-castro"],
                    summary: "Accesos con doble factor y registros de auditoría para todo lo que se migra.",
                    points: ["Requisito de Nubia: [[cumplimiento-regulatorio]]"]),
            ],
            tasks: [
                ("Confirmar la ventana de mantenimiento con Acme", "jaime-ruiz", -3, nil, "seguimiento"),
                ("Documentar la vuelta atrás del corte", "valeria-ortiz", -8, nil, "simulacro"),
                ("Revisar cuántos años de respaldos conservar", "elena-castro", 2, nil, "simulacro"),
                ("Apagar los ocho servidores sin uso", "diego-paredes", 20, 15, "inventario-reunion"),
                ("Firmar el contrato con el proveedor A", "carlos-vega", 40, 38, "revision-costos"),
                ("Calcular el costo a tres años", nil, 55, 52, "cotizacion"),
            ],
            milestones: [(-100, "Fin de la migración (planeado)"), (30, "Fase 1 terminada")],
            state: "La fase 1 terminó; la base de datos de clientes se migra en la ventana de noviembre."
        ),
        ProjectSpec(
            name: "Alianza Banco Nubia", emoji: "🤝", description: "Pagos de Nubia dentro de nuestras apps",
            docs: [
                Doc(key: "sitio-nubia", kind: .url, title: "Programa de socios de Banco Nubia", daysAgo: 71,
                    people: ["marta-rios"],
                    summary: "Página pública del programa de socios: requisitos y comisiones de referencia.",
                    points: ["Comisión de referencia: 2 %", "Requisitos de [[cumplimiento-regulatorio]]"]),
                Doc(key: "primera-reunion", kind: .meeting, title: "Primera reunión con Nubia", daysAgo: 70, hour: 12,
                    people: ["jaime-ruiz", "marta-rios", "andres-silva", "lucia-romero"],
                    summary: "[[marta-rios|Marta]] y [[andres-silva|Andrés]] quieren sus pagos dentro de [[app-movil-atlas|Atlas]].",
                    points: ["Interés en la [[integracion-de-pagos]]", "Primera idea del [[modelo-de-comisiones]]", "Referencia: [[@sitio-nubia]]"]),
                Doc(key: "taller-pagos", kind: .meeting, title: "Taller de integración de pagos", daysAgo: 52, hour: 10,
                    people: ["andres-silva", "luis-torres", "jaime-ruiz"],
                    summary: "Taller técnico con [[andres-silva|Andrés]] sobre la API de pagos.",
                    points: ["La API necesita la [[base-de-datos-clientes]] en la nube", "Nubia enviará datos de prueba ([[@datos-prueba]])"]),
                Doc(key: "borrador", kind: .email, title: "Borrador del convenio con Nubia", daysAgo: 40, hour: 16,
                    people: ["marta-rios", "elena-castro", "jaime-ruiz"],
                    summary: "✉️ [[elena-castro|Elena]] y [[marta-rios|Marta]] intercambian el borrador del convenio.",
                    points: ["Puntos abiertos: exclusividad y [[modelo-de-comisiones|comisiones]]"]),
                Doc(key: "term-sheet", kind: .document, title: "Term sheet de la alianza", daysAgo: 38,
                    people: ["marta-rios", "carlos-vega"],
                    summary: "Resumen de condiciones: comisiones, duración y piloto.",
                    points: ["Dos años renovables", "Piloto inicial antes de abrir a todos"]),
                Doc(key: "negociacion", kind: .meeting, title: "Negociación comercial", daysAgo: 35, hour: 11,
                    people: ["jaime-ruiz", "marta-rios", "carlos-vega"],
                    summary: "Se cerró la comisión en 1,5 % tras revisar el [[@term-sheet|term sheet]].",
                    points: ["Decisión: [[@dec-comision]]", "[[carlos-vega|Carlos]] valida el impacto en la [[campana-lanzamiento|campaña]] conjunta"]),
                Doc(key: "dec-comision", kind: .decision, title: "Comisión del 1,5 %", daysAgo: 35,
                    people: ["carlos-vega", "marta-rios"],
                    summary: "Comisión por transacción del 1,5 % durante los dos primeros años.",
                    points: ["Alternativa descartada: 2 % con exclusividad", "Ver [[modelo-de-comisiones]]"]),
                Doc(key: "datos-prueba", kind: .email, title: "Datos de prueba de la API", daysAgo: 22, hour: 10,
                    people: ["andres-silva", "luis-torres"],
                    summary: "✉️ [[andres-silva|Andrés]] envía tarjetas de prueba; dos fallan en la beta de Atlas.",
                    points: ["Relacionado con el error de [[@resultados-beta]]"]),
                Doc(key: "revision-legal", kind: .meeting, title: "Revisión legal del convenio", daysAgo: 15, hour: 15,
                    people: ["elena-castro", "marta-rios", "jaime-ruiz"],
                    summary: "El convenio está casi listo; falta saber quién firma por Nubia.",
                    points: ["Pregunta: [[quien-firma-por-nubia]]", "Piloto acordado → [[@dec-piloto]]", "[[cumplimiento-regulatorio]] revisado"]),
                Doc(key: "dec-piloto", kind: .decision, title: "Piloto con 500 clientes", daysAgo: 15,
                    people: ["marta-rios", "jaime-ruiz"],
                    summary: "Antes de abrir a todos, un piloto de seis semanas con 500 clientes de Atlas.",
                    points: ["Arranca después del lanzamiento de Atlas ([[plan-de-lanzamiento]])"]),
                Doc(key: "quien-firma-por-nubia", kind: .question, title: "¿Quién firma el convenio por Nubia?", daysAgo: 15,
                    people: ["marta-rios", "elena-castro"],
                    summary: "Marta cree que firma el director general; Elena necesita el poder notarial.",
                    points: ["Bloquea la firma del convenio"]),
                Doc(key: "comite", kind: .meeting, title: "Comité de la alianza", daysAgo: 1, hour: 9,
                    people: ["jaime-ruiz", "marta-rios", "andres-silva", "carlos-vega"],
                    summary: "Comité mensual: el piloto arranca en enero si se firma en noviembre.",
                    points: ["Pendiente: [[quien-firma-por-nubia]]", "[[integracion-de-pagos|Integración]] lista al 80 %"]),
                Doc(key: "integracion-de-pagos", kind: .topic, title: "Integración de pagos",
                    people: ["andres-silva", "luis-torres"],
                    summary: "Pagos de Nubia dentro de Atlas a través de su API.",
                    points: ["Taller: [[@taller-pagos]]", "Datos de prueba: [[@datos-prueba]]", "Depende de [[base-de-datos-clientes]]"]),
                Doc(key: "modelo-de-comisiones", kind: .topic, title: "Modelo de comisiones",
                    people: ["carlos-vega", "marta-rios"],
                    summary: "Cómo se reparten los ingresos por transacción.",
                    points: ["Decisión: [[@dec-comision]]", "Term sheet: [[@term-sheet]]"]),
                Doc(key: "cumplimiento-regulatorio", kind: .topic, title: "Cumplimiento regulatorio",
                    people: ["elena-castro", "andres-silva"],
                    summary: "Requisitos del regulador bancario para los socios de Nubia.",
                    points: ["Auditoría de accesos: [[seguridad-y-accesos]]", "Conservación de datos: [[respaldo-de-datos-historicos]]"]),
            ],
            tasks: [
                ("Conseguir el poder notarial del firmante", "marta-rios", -6, nil, "revision-legal"),
                ("Enviar la versión final del convenio", "elena-castro", -1, nil, "comite"),
                ("Preparar la lista de clientes del piloto", "jaime-ruiz", -20, nil, "comite"),
                ("Corregir las tarjetas de prueba que fallan", "andres-silva", 8, nil, "datos-prueba"),
                ("Revisar el term sheet", "carlos-vega", 36, 36, "term-sheet"),
            ],
            milestones: [(-60, "Arranque del piloto (planeado)")],
            state: "Convenio casi listo; falta confirmar quién firma por Nubia. El piloto arrancaría en enero."
        ),
    ]
    // swiftlint:enable line_length

    // MARK: Writer

    static func create(at root: URL, scale: Int) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = VaultStore(root: root)
        try vault.migrateIfNeeded()
        try vault.setOwnerName("Jaime Ruiz")
        try vault.setOwnerEmails(["jaime.ruiz@ejemplo.com"])   // v0.7: "Tú" in the conversation, own replies
        let manager = ProjectManager(vaultRoot: root)
        let today = Calendar.current.startOfDay(for: Date())
        func day(_ daysAgo: Int, hour: Int = 0) -> Date {
            Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!)!
        }
        func ymd(_ d: Date) -> String { fmt(d, "yyyy-MM-dd") }

        var pageCount = 0
        var created: [Project] = []
        for spec in projects {
            let project = try manager.create(name: spec.name, description: spec.description, emoji: spec.emoji)
            created.append(project)
            let slug = project.slug
            let wiki = "projects/\(slug)/wiki"

            // File names (depend on dates).
            var names: [String: String] = [:]
            for doc in spec.docs { names[doc.key] = otherName(doc, today: today) }
            func sourceTitle(_ key: String) -> String { spec.docs.first { $0.key == key }?.title ?? key }
            func expand(_ text: String) -> String {
                var out = text
                for (key, name) in names {
                    out = out.replacingOccurrences(of: "[[@\(key)|", with: "[[\(name)|")
                    if let title = spec.docs.first(where: { $0.key == key })?.title {
                        out = out.replacingOccurrences(of: "[[@\(key)]]", with: "[[\(name)|\(title)]]")
                    }
                }
                // Links to pages of other projects by key (e.g. [[@resultados-beta]]).
                for other in projects where other.name != spec.name {
                    for doc in other.docs where out.contains("[[@\(doc.key)") {
                        let name = otherName(doc, today: today)
                        out = out.replacingOccurrences(of: "[[@\(doc.key)]]", with: "[[\(name)|\(doc.title)]]")
                        out = out.replacingOccurrences(of: "[[@\(doc.key)|", with: "[[\(name)|")
                    }
                }
                // Bare links to topics and questions get their title as label, as Claude writes them.
                for other in projects {
                    for doc in other.docs where (doc.kind == .topic || doc.kind == .question) && out.contains("[[\(doc.key)]]") {
                        out = out.replacingOccurrences(of: "[[\(doc.key)]]", with: "[[\(doc.key)|\(doc.title)]]")
                    }
                }
                return out
            }

            for doc in spec.docs {
                let name = names[doc.key]!
                let date = doc.daysAgo.map { day($0, hour: doc.hour) }
                var fm: [String] = ["---"]
                let peopleList = "[" + doc.people.map { "\"[[\($0)]]\"" }.joined(separator: ", ") + "]"
                var folder: String
                var body: [String] = ["# \(doc.title)", "", "> **En breve:** \(expand(doc.summary))", ""]
                switch doc.kind {
                case .meeting:
                    folder = "meetings"
                    let d = date!
                    fm += ["type: meeting", "title: \"\(doc.title)\"", "project: \(slug)", "date: \(ymd(d))", "time: \"\(fmt(d, "HH:mm"))\"",
                           "event_date: \"\(SBDate.iso(d))\"", "duration: \"00:\(30 + doc.people.count * 4):00\"", "language: es", "template: estandar",
                           "sources: [\"projects/\(slug)/raw/meetings/\(name).md\"]", "people: \(peopleList)", "status: processed", "updated: \(ymd(d))"]
                    body += ["**Fecha:** \(fmt(d, "yyyy-MM-dd HH:mm")) · **Participantes:** " + doc.people.map { personLink($0) }.joined(separator: ", "), "",
                             "## Temas tratados"] + doc.points.map { "- " + expand($0) + " (00:\(String(format: "%02d", 3 + ($0.count * 7) % 50)):\(String(format: "%02d", $0.count % 60)))" }
                    let mine = spec.tasks.filter { $0.source == doc.key }
                    if !mine.isEmpty {
                        body += ["", "## Acuerdos"] + mine.map { t in
                            let who = t.owner.map { personLink($0) } ?? "Sin dueño"
                            return "- **\(who):** \(t.text.prefix(1).lowercased() + t.text.dropFirst())" + (t.dueDaysAgo.map { " · 📅 \(ymd(day($0)))" } ?? "")
                        }
                    }
                    body += ["", "## Fuente", "[[projects/\(slug)/raw/meetings/\(name)|Transcripción completa]]"]
                    try write(root, "projects/\(slug)/raw/meetings/\(name).md", transcript(doc, date: d, slug: slug))
                case .email:
                    folder = "emails"
                    let d = date!
                    let sender = doc.people.first!
                    let reply = doc.people.dropFirst().first ?? "jaime-ruiz"
                    let m1 = "\(fmt(d, "yyyy-MM-dd-HHmm"))-\(sender)"
                    let d2 = d.addingTimeInterval(26 * 3600)
                    let m2 = "\(fmt(d2, "yyyy-MM-dd-HHmm"))-\(reply)"
                    fm += ["type: email-thread", "title: \"\(doc.title)\"", "project: \(slug)", "thread: \(name)", "subject: \"\(doc.title)\"",
                           "date: \(ymd(d))", "event_date: \"\(SBDate.iso(d))\"", "last_message: \"\(SBDate.iso(d2))\"", "messages: 2", "language: es",
                           "template: correo-hilo", "people: \(peopleList)", "status: open", "updated: \(ymd(d2))"]
                    body += ["**Hilo de correo** · 2 correos · del \(ymd(d)) al \(ymd(d2)) · **Participantes:** " + doc.people.map { personLink($0) }.joined(separator: ", "), "",
                             "## Cronología",
                             "- **\(fmt(d, "yyyy-MM-dd HH:mm"))** · \(personLink(sender)) → \(personLink(reply)): \(expand(doc.points.first ?? doc.summary)) ([[\(m1)]])",
                             "- **\(fmt(d2, "yyyy-MM-dd HH:mm"))** · \(personLink(reply)) → \(personLink(sender)): responde ([[\(m2)]])", ""]
                    if doc.points.count > 1 { body += ["## Estado actual"] + doc.points.dropFirst().map { "- " + expand($0) } + [""] }
                    body += ["## Fuente", "- ✉️ [[projects/\(slug)/raw/emails/\(name)/\(m1)|Correo de \(personName(sender))]]",
                             "- ✉️ [[projects/\(slug)/raw/emails/\(name)/\(m2)|Correo de \(personName(reply))]]"]
                    try write(root, "projects/\(slug)/raw/emails/\(name)/\(m1).md", rawEmail(from: sender, to: reply, subject: doc.title, date: d, text: plain(doc.summary)))
                    try write(root, "projects/\(slug)/raw/emails/\(name)/\(m2).md", rawEmail(from: reply, to: sender, subject: "Re: " + doc.title, date: d2, text: "Gracias, lo reviso y te confirmo."))
                case .document, .note, .url:
                    folder = "sources"
                    let d = date ?? today
                    let ext = doc.kind == .document ? "md" : "md"
                    let rawDir = doc.kind == .document ? "docs" : "notes"
                    fm += ["type: source", "source_type: \(doc.kind.rawValue)", "title: \"\(doc.title)\"", "project: \(slug)", "date: \(ymd(d))",
                           "event_date: \"\(SBDate.iso(d))\"", "language: es", "sources: [\"projects/\(slug)/raw/\(rawDir)/\(name).\(ext)\"]",
                           "people: \(peopleList)", "status: processed", "updated: \(ymd(d))"]
                    if doc.kind == .url { fm.append("source_url: \"https://nubia.example/socios\"") }
                    body += ["**Fecha:** \(ymd(d))", "", "## Puntos clave"] + doc.points.map { "- " + expand($0) }
                    body += ["", "## Fuente", "[[projects/\(slug)/raw/\(rawDir)/\(name)|Original]]"]
                    try write(root, "projects/\(slug)/raw/\(rawDir)/\(name).md", "---\ntype: \(doc.kind.rawValue)\ndate: \(SBDate.iso(d))\n---\n\n# \(doc.title)\n\n\(plain(doc.summary))\n")
                case .topic:
                    folder = "topics"
                    fm += ["type: topic", "title: \"\(doc.title)\"", "project: \(slug)", "language: es", "people: \(peopleList)", "status: active", "updated: \(ymd(today))"]
                    body += ["## Estado actual"] + doc.points.map { "- " + expand($0) }
                    let mentions = spec.docs.filter { ($0.kind == .meeting || $0.kind == .email) && ($0.points + [$0.summary]).joined().contains("[[\(doc.key)") }
                    if !mentions.isEmpty {
                        body += ["", "## Historia"] + mentions.sorted { ($0.daysAgo ?? 0) > ($1.daysAgo ?? 0) }.map {
                            "- **\(ymd(day($0.daysAgo ?? 0)))** — \($0.title) ([[\(names[$0.key]!)]])"
                        }
                    }
                    body += ["", "## Relacionado", doc.people.map { personLink($0) }.joined(separator: " · ")]
                case .decision:
                    folder = "decisions"
                    let d = date!
                    let superseded = doc.summary.contains("Reemplazada")
                    fm += ["type: decision", "title: \"\(doc.title)\"", "project: \(slug)", "date: \(ymd(d))", "status: \(superseded ? "superseded" : "accepted")",
                           "decided_by: \(peopleList)", "language: es", "people: \(peopleList)", "updated: \(ymd(d))"]
                    body += ["## Decisión", expand(doc.summary), "", "## Consecuencias"] + doc.points.map { "- " + expand($0) }
                case .question:
                    folder = "questions"
                    let d = date ?? today
                    fm += ["type: question", "title: \"\(doc.title)\"", "project: \(slug)", "date: \(ymd(d))", "status: open", "origin: meeting",
                           "language: es", "people: \(peopleList)", "updated: \(ymd(d))"]
                    body += ["## Estado"] + doc.points.map { "- " + expand($0) }
                }
                fm.append("---")
                try write(root, "\(wiki)/\(folder)/\(name).md", (fm + [""] + body).joined(separator: "\n") + "\n")
                pageCount += 1
            }

            // overview.md
            let meetings = spec.docs.filter { $0.kind == .meeting }.sorted { ($0.daysAgo ?? 0) < ($1.daysAgo ?? 0) }
            let topics = spec.docs.filter { $0.kind == .topic }
            let decisions = spec.docs.filter { $0.kind == .decision }
            let team = Array(Set(spec.docs.flatMap(\.people))).sorted()
            var overview = ["---", "type: overview", "title: \"\(spec.name)\"", "project: \(slug)", "language: es", "status: active", "updated: \(ymd(today))", "---", "",
                            "# \(spec.name)", "", "> **En breve:** \(spec.state)", "", "## Objetivo", spec.description, "", "## Estado actual", spec.state, "",
                            "## Decisiones clave"]
            overview += decisions.map { "- [[\(names[$0.key]!)|\($0.title)]] · \(ymd(day($0.daysAgo ?? 0)))" }
            overview += ["", "## Temas"] + topics.map { "- [[\($0.key)|\($0.title)]] — \(expand($0.summary))" }
            overview += ["", "## Personas"] + team.map { "- \(personLink($0))" }
            overview += ["", "## Línea de tiempo"] + meetings.prefix(4).map { "- \(ymd(day($0.daysAgo ?? 0))) · 🎙️ [[\(names[$0.key]!)|\($0.title)]]" }
            overview += ["", "La historia completa está en la [[projects/\(slug)/wiki/timeline|línea de tiempo]]. Pendientes: [[projects/\(slug)/wiki/tasks|pendientes]]."]
            try write(root, "\(wiki)/overview.md", overview.joined(separator: "\n") + "\n")

            // tasks.md
            var tasks = ["---", "type: tasks", "title: \"\(spec.name) — pendientes\"", "project: \(slug)", "language: es", "updated: \(ymd(today))", "---", "",
                         "# \(spec.name) — pendientes", "", "Compromisos del proyecto: quién, qué y para cuándo. 📅 = fecha límite · ✅ = hecho.", "", "## Abiertas", ""]
            let open = spec.tasks.filter { $0.doneDaysAgo == nil }
            let owners = Array(Set(open.compactMap(\.owner))).sorted { a, b in a == "jaime-ruiz" ? true : b == "jaime-ruiz" ? false : a < b }
            for owner in owners {
                tasks.append(owner == "jaime-ruiz" ? "### Yo — [[\(owner)|\(personName(owner))]]" : "### [[\(owner)|\(personName(owner))]]")
                for t in open where t.owner == owner {
                    tasks.append("- [ ] \(t.text) — [[\(owner)|\(personName(owner))]]" + (t.dueDaysAgo.map { " · 📅 \(ymd(day($0)))" } ?? "") + " · ([[\(names[t.source]!)|\(sourceTitle(t.source))]])")
                }
                tasks.append("")
            }
            tasks += ["## Sin dueño", ""]
            for t in open where t.owner == nil { tasks.append("- [ ] \(t.text)" + (t.dueDaysAgo.map { " · 📅 \(ymd(day($0)))" } ?? "") + " · ([[\(names[t.source]!)|\(sourceTitle(t.source))]])") }
            tasks += ["", "## Hechas", ""]
            for t in spec.tasks.filter({ $0.doneDaysAgo != nil }).sorted(by: { $0.doneDaysAgo! < $1.doneDaysAgo! }) {
                let who = t.owner.map { " — [[\($0)|\(personName($0))]]" } ?? ""
                tasks.append("- [x] \(t.text)\(who)" + (t.dueDaysAgo.map { " · 📅 \(ymd(day($0)))" } ?? "") + " · ✅ \(ymd(day(t.doneDaysAgo!))) · ([[\(names[t.source]!)|\(sourceTitle(t.source))]])")
            }
            try write(root, "\(wiki)/tasks.md", tasks.joined(separator: "\n") + "\n")

            // timeline.md
            var entries: [(Date, String)] = []
            for doc in spec.docs {
                guard let ago = doc.daysAgo else { continue }
                let d = day(ago, hour: doc.hour)
                let link = "[[\(names[doc.key]!)|\(doc.title)]]"
                switch doc.kind {
                case .meeting: entries.append((d, "- \(fmt(d, "yyyy-MM-dd HH:mm")) · 🎙️ \(link) — \(firstSentence(expand(doc.summary)))"))
                case .email: entries.append((d, "- \(fmt(d, "yyyy-MM-dd HH:mm")) · ✉️ \(link) — \(firstSentence(expand(doc.summary)))"))
                case .decision: entries.append((day(ago), "- \(ymd(d)) · ⚖️ \(link) — \(firstSentence(expand(doc.summary)))"))
                case .document: entries.append((day(ago), "- \(ymd(d)) · 📄 \(link)"))
                case .note: entries.append((day(ago), "- \(ymd(d)) · 📝 \(link)"))
                case .url: entries.append((day(ago), "- \(ymd(d)) · 🔗 \(link)"))
                default: break
                }
            }
            for m in spec.milestones { entries.append((day(m.daysAgo), "- \(ymd(day(m.daysAgo))) · 🚩 \(m.text)")) }
            entries.sort { $0.0 < $1.0 }
            var timeline = ["---", "type: timeline", "title: \"\(spec.name) — línea de tiempo\"", "project: \(slug)", "language: es", "updated: \(ymd(today))", "---", "",
                            "# \(spec.name) — línea de tiempo", "",
                            "Lo que pasó en el proyecto, por la fecha en que pasó (no por cuándo se agregó). 🎙️ reunión · ✉️ correo · 📄 documento · 📝 nota · 🔗 página web · ⚖️ decisión · 🚩 hito · 📅 fecha límite"]
            var month = ""
            for (d, line) in entries {
                let m = monthTitle(d)
                if m != month { timeline += ["", "## \(m)"]; month = m }
                timeline.append(line)
            }
            try write(root, "\(wiki)/timeline.md", timeline.joined(separator: "\n") + "\n")

            // index.md of the project (navigation: not in the graph, but the app and Claude read it).
            var index = ["---", "type: index", "title: \"\(spec.name) — índice\"", "project: \(slug)", "language: es", "updated: \(ymd(today))", "---", "",
                         "# \(spec.name) — índice", "", "## Navegación",
                         "- [[projects/\(slug)/wiki/overview|Resumen]] · [[projects/\(slug)/wiki/tasks|Pendientes]] · [[projects/\(slug)/wiki/timeline|Línea de tiempo]]", ""]
            for (heading, kinds) in [("Reuniones", [Kind.meeting]), ("Correos", [.email]), ("Fuentes", [.document, .note, .url]), ("Temas", [.topic]),
                                     ("Decisiones", [.decision]), ("Preguntas", [.question])] {
                let docs = spec.docs.filter { kinds.contains($0.kind) }
                guard !docs.isEmpty else { continue }
                index += ["## \(heading)"] + docs.map { "- [[\(names[$0.key]!)|\($0.title)]]" + ($0.daysAgo.map { " · \(ymd(day($0)))" } ?? "") } + [""]
            }
            try write(root, "\(wiki)/index.md", index.joined(separator: "\n"))
            try write(root, "\(wiki)/log.md", "---\ntype: log\nproject: \(slug)\n---\n\n# Registro\n\n## [\(ymd(today))] create | \(spec.name)\n- Proyecto creado con [[projects/\(slug)/wiki/overview|resumen]]\n")
            pageCount += 4
        }

        // People.
        for person in people {
            let mine = projects.enumerated().filter { person.projects.contains(slugify($0.element.name)) }
            var lines = ["---", "type: person", "title: \"\(person.name)\"", "aliases: " + "[" + person.aliases.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
                         "role: \"\(person.role)\"", "organization: \"\(person.org)\""]
            if let org = orgKey(person.org) { lines.append("org: \"[[\(org)]]\"") }
            lines += [
                         "projects: [" + person.projects.map { "\"\($0)\"" }.joined(separator: ", ") + "]", "language: es",
                         "owner: \(person.key == "jaime-ruiz")", "updated: \(ymd(today))", "---", "", "# \(person.name)", "",
                         "> **En breve:** \(person.role) en " + (orgKey(person.org).map { "[[\($0)|\(person.org)]]" } ?? person.org) + ".",
                         "", "## Proyectos"]
            lines += mine.map { "- **[[projects/\(slugify($0.element.name))/wiki/overview|\($0.element.emoji) \($0.element.name)]]**" }
            let open = projects.flatMap { p in p.tasks.filter { $0.owner == person.key && $0.doneDaysAgo == nil }.map { (p, $0) } }
            if !open.isEmpty {
                lines += ["", "## Compromisos"] + open.map { p, t in
                    "- \(t.text)" + (t.dueDaysAgo.map { " · 📅 \(ymd(day($0)))" } ?? "") + " · [[projects/\(slugify(p.name))/wiki/tasks|\(p.name)]]"
                }
            }
            let meetings = projects.flatMap { p in p.docs.filter { $0.kind == .meeting && $0.people.contains(person.key) } }
            if !meetings.isEmpty {
                lines += ["", "## En reuniones"] + meetings.map { "- [[\(otherName($0, today: today))|\($0.title)]]" }
            }
            let emails = projects.flatMap { p in p.docs.filter { $0.kind == .email && $0.people.contains(person.key) } }
            if !emails.isEmpty {
                lines += ["", "## Correos"] + emails.map { "- ✉️ [[\(otherName($0, today: today))|\($0.title)]]" }
            }
            try write(root, "people/\(person.key).md", lines.joined(separator: "\n") + "\n")
        }

        // Organizations (orgs/), linked from their people and the global index.
        for org in orgs {
            let members = people.filter { orgKey($0.org) == org.key }
            let mine = projects.filter { org.projects.contains(slugify($0.name)) }
            var lines = ["---", "type: org", "title: \"\(org.name)\"",
                         "aliases: [" + org.aliases.map { "\"\($0)\"" }.joined(separator: ", ") + "]", "kind: \(org.kind)",
                         "projects: [" + org.projects.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
                         "people: [" + members.map { "\"[[\($0.key)]]\"" }.joined(separator: ", ") + "]",
                         "language: es", "updated: \(ymd(today))", "---", "", "# \(org.name)", "", "> **En breve:** \(org.summary)", "",
                         "## Proyectos"]
            lines += mine.map { "- **[[projects/\(slugify($0.name))/wiki/overview|\($0.emoji) \($0.name)]]**" }
            lines += ["", "## Personas"] + members.map { "- [[\($0.key)|\($0.name)]] — \($0.role)" }
            try write(root, "orgs/\(org.key).md", lines.joined(separator: "\n") + "\n")
        }

        // A confirmed fact (§16.6), so "Hechos confirmados" has content.
        let factsURL = root.appendingPathComponent(Corrections.factsPath)
        if var facts = try? String(contentsOf: factsURL, encoding: .utf8),
           let line = Corrections.factLine("Diego Paredes no forma parte de 🚀 Lanzamiento Atlas: solo colabora en la migración. "
                                            + "([[diego-paredes]], [[projects/lanzamiento-atlas/wiki/overview|Lanzamiento Atlas]])",
                                           date: day(2)) {
            if !facts.hasSuffix("\n") { facts += "\n" }
            try (facts + line + "\n").write(to: factsURL, atomically: true, encoding: .utf8)
        }

        // Global index: projects (added by ProjectManager) + people + companies.
        let indexURL = root.appendingPathComponent("index.md")
        var index = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? "# Mi segundo cerebro\n"
        let peopleLines = people.map { "- [[\($0.key)|\($0.name)]] — \($0.role), \($0.org)" }.joined(separator: "\n")
        if let range = index.range(of: "## Personas\n") {
            index.replaceSubrange(range, with: "## Personas\n\n\(peopleLines)\n")
        } else {
            index += "\n## Personas\n\n\(peopleLines)\n"
        }
        let orgLines = orgs.map { "- [[\($0.key)|\($0.name)]] — \($0.summary)" }.joined(separator: "\n")
        if let range = index.range(of: "## Empresas\n") {
            index.replaceSubrange(range, with: "## Empresas\n\n\(orgLines)\n")
        } else {
            index += "\n## Empresas\n\n\(orgLines)\n"
        }
        try index.write(to: indexURL, atomically: true, encoding: .utf8)

        if scale > 0 { try addSynthetic(root: root, projects: created, scale: scale, today: today) }

        let rules = try addSampleRules(root: root, projects: created, today: today)
        try DemoFiles.add(root: root)   // v0.7 files (§17.2)
        try DemoThreads.enrich(root: root)   // v0.7 (§17.8): a long thread with my reply and its Outlook links
        try DemoThreads.describeOthers(root: root)   // v0.7 fix: every demo thread is one row with its count

        return "Created \(root.path): \(created.count) projects, \(pageCount) project pages, \(people.count) people, \(orgs.count) companies, \(rules) routing rules"
            + (scale > 0 ? ", plus \(scale) synthetic meetings per project" : "")
    }

    /// v0.4 routing (CONTRACT §14): two rules so every screen shows routing at work with the demo accounts
    /// (`SB_DEMO_ACCOUNTS=1`): mail from @acmelogistics.com → 🚀 Lanzamiento Atlas (added by itself), and anything whose
    /// subject or title says "2027" (the budget mail and meeting, in both languages) → ☁️ Migración a la nube.
    static func addSampleRules(root: URL, projects: [Project], today: Date) throws -> Int {
        func slug(_ name: String) -> String? { projects.first { $0.name == name }?.slug }
        guard let atlas = slug("Lanzamiento Atlas"), let cloud = slug("Migración a la nube") else { return 0 }
        let created = Calendar.current.date(byAdding: .day, value: -21, to: today) ?? today
        let lastHit = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let rules = [
            RoutingRule(conditions: [RuleCondition(field: .senderDomain, op: .is, value: "acmelogistics.com")], projectSlug: atlas,
                        autoAddMail: true, createdAt: created, hits: 9, lastHitAt: lastHit),
            RoutingRule(conditions: [RuleCondition(field: .subject, op: .contains, value: "2027")], projectSlug: cloud,
                        createdAt: created, hits: 3, lastHitAt: lastHit),
        ]
        let url = RoutingStore.fileURL(vaultRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(RoutingSettings(rules: rules)).write(to: url, options: .atomic)
        return rules.count
    }

    /// Stress test: N meetings per project, N/5 topics, N/10 people, randomly (but reproducibly) linked.
    static func addSynthetic(root: URL, projects: [Project], scale: Int, today: Date) throws {
        var rng = SeededRandom(seed: 42)
        let extraPeople = (0..<max(4, scale / 10)).map { "persona-\($0)" }
        for p in extraPeople {
            let n = Int(p.split(separator: "-")[1])!
            let slugs = projects.map(\.slug).shuffled(using: &rng).prefix(1 + n % 2)
            try write(root, "people/\(p).md", "---\ntype: person\ntitle: \"Persona \(n)\"\nprojects: [\(slugs.map { "\"\($0)\"" }.joined(separator: ", "))]\n---\n\n# Persona \(n)\n")
        }
        for project in projects {
            let topics = (0..<max(3, scale / 5)).map { "tema-\(project.slug)-\($0)" }
            for (i, t) in topics.enumerated() {
                let link = topics[Int.random(in: 0..<topics.count, using: &rng)]
                try write(root, "projects/\(project.slug)/wiki/topics/\(t).md",
                          "---\ntype: topic\ntitle: \"Tema \(i) de \(project.name)\"\n---\n\n# Tema \(i) de \(project.name)\n\nRelacionado: [[\(link)]]\n")
            }
            for i in 0..<scale {
                let d = Calendar.current.date(byAdding: .minute, value: -Int.random(in: 60...(90 * 24 * 60), using: &rng), to: today)!
                let name = "\(fmt(d, "yyyy-MM-dd-HHmm"))-sintetica-\(i)"
                var links: [String] = []
                for _ in 0..<Int.random(in: 1...3, using: &rng) { links.append(topics[Int.random(in: 0..<topics.count, using: &rng)]) }
                for _ in 0..<Int.random(in: 1...3, using: &rng) { links.append(extraPeople[Int.random(in: 0..<extraPeople.count, using: &rng)]) }
                if Int.random(in: 0..<4, using: &rng) == 0 { links.append(people[Int.random(in: 0..<people.count, using: &rng)].key) }
                try write(root, "projects/\(project.slug)/wiki/meetings/\(name).md",
                          "---\ntype: meeting\ntitle: \"Reunión \(i)\"\ndate: \(fmt(d, "yyyy-MM-dd"))\nevent_date: \"\(SBDate.iso(d))\"\n---\n\n# Reunión \(i)\n\n"
                            + links.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n")
            }
        }
    }

    // MARK: Helpers

    static func otherName(_ doc: Doc, today: Date) -> String {
        let d = Calendar.current.date(byAdding: .hour, value: doc.hour,
                                      to: Calendar.current.date(byAdding: .day, value: -(doc.daysAgo ?? 0), to: today)!)!
        switch doc.kind {
        case .meeting: return "\(fmt(d, "yyyy-MM-dd-HHmm"))-\(slugify(doc.title, maxLength: 30))"
        case .email: return slugify(doc.title, maxLength: 40)
        case .decision: return "\(fmt(d, "yyyy-MM-dd"))-\(slugify(doc.title, maxLength: 40))"
        case .document, .note, .url: return "\(fmt(d, "yyyy-MM-dd"))-\(slugify(doc.title, maxLength: 30))"
        case .question: return doc.key
        case .topic: return doc.key
        }
    }

    static func personName(_ key: String) -> String { people.first { $0.key == key }?.name ?? key }
    static func personLink(_ key: String) -> String {
        let name = personName(key)
        return key == "jaime-ruiz" ? "[[\(key)|\(name.split(separator: " ").first ?? "")]] (yo)" : "[[\(key)|\(name)]]"
    }

    /// Text without wikilinks (labels kept): transcripts and raw files have no links.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[\[@?[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[@?([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
    }

    static func firstSentence(_ s: String) -> String {
        let plain = s.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "✉️ ", with: "")
        return plain.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? plain
    }

    static func transcript(_ doc: Doc, date: Date, slug: String) -> String {
        var lines = ["---", "type: transcript", "title: \"\(doc.title)\"", "project: \(slug)", "date: \(SBDate.iso(date))", "language: es", "---", "",
                     "# \(doc.title)", ""]
        for (i, p) in doc.people.enumerated() {
            let speaker = p == "jaime-ruiz" ? "Yo" : "Hablante \(i)"
            lines.append("**[00:0\(i):1\(i)] \(speaker):** \(plain(doc.points[safe: i] ?? doc.summary))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func rawEmail(from: String, to: String, subject: String, date: Date, text: String) -> String {
        let mail: (String) -> String = { "\($0.replacingOccurrences(of: "-", with: "."))@ejemplo.com" }
        return "---\ntype: email\nsubject: \"\(subject)\"\nfrom: \"\(personName(from)) <\(mail(from))>\"\nto: [\"\(personName(to)) <\(mail(to))>\"]\ndate: \(SBDate.iso(date))\n---\n\n\(text)\n"
    }

    static func monthTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "LLLL yyyy"
        let s = f.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func fmt(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: d)
    }

    static func write(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Reproducible RNG for the synthetic pages (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
