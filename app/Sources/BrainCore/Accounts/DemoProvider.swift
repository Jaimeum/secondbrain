import Foundation

/// Invented but believable mail and calendar (es/en) for snapshots and UX review without real accounts
/// (`SB_DEMO_ACCOUNTS=1`, CONTRACT §12.3). Dates are relative to when the provider is created.
///
/// Microsoft account (ana@contoso.com): 12 emails over the last 10 days from 5 people (two threads) and 8 events from
/// yesterday to +7 days, one of them in progress (started 10 min ago, ends in 50 min, Teams link).
/// Google account (demo@gmail.com): a few personal emails and two events.
public final class DemoProvider: MailCalendarProvider {
    public let account: ConnectedAccount
    private let messages: [MailMessageFull]
    private let calendar: [CalendarEvent]

    public init(account: ConnectedAccount, language: String = "es", now: Date = Date()) {
        self.account = account
        let data = DemoData(account: account, lang: Lang(language), now: now)
        messages = data.messages.sorted { $0.summary.date > $1.summary.date }
        calendar = data.events.sorted { $0.start < $1.start }
    }

    public static func demoAccount(_ provider: AccountProvider) -> ConnectedAccount {
        switch provider {
        case .microsoft:
            ConnectedAccount(provider: .microsoft, email: "ana@contoso.com", displayName: "Ana García",
                             connectedAt: Date().addingTimeInterval(-86_400 * 3), scopes: provider.scopes)
        case .google:
            ConnectedAccount(provider: .google, email: "demo@gmail.com", displayName: "Ana García",
                             connectedAt: Date().addingTimeInterval(-86_400), scopes: provider.scopes)
        }
    }

    public func profile() async throws -> ConnectedAccount { account }

    public func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        page(messages.filter { $0.summary.date >= since }.map(\.summary), token: pageToken)
    }

    public func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return page(messages.map(\.summary), token: pageToken) }
        let hits = messages.filter { m in
            [m.summary.subject, m.summary.snippet, m.bodyText, m.summary.from.display, m.summary.from.email ?? ""]
                .contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return page(hits.map(\.summary), token: pageToken)
    }

    public func fetchMessage(id: String) async throws -> MailMessageFull {
        guard let m = messages.first(where: { $0.summary.id == id }) else { throw AccountError.failed("demo message \(id) not found") }
        return m
    }

    public func fetchThread(id: String) async throws -> [MailMessageFull] {
        messages.filter { $0.summary.threadId == id }.sorted { $0.summary.date < $1.summary.date }
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        calendar.filter { $0.end > from && $0.start < to }
    }

    /// 5 per page, so "Cargar más" can be exercised.
    private func page(_ list: [MailMessageSummary], token: String?) -> (messages: [MailMessageSummary], next: String?) {
        let size = 5
        let start = token.flatMap(Int.init) ?? 0
        guard start < list.count else { return ([], nil) }
        let end = min(start + size, list.count)
        return (Array(list[start..<end]), end < list.count ? String(end) : nil)
    }
}

// MARK: - Data

private struct DemoData {
    var messages: [MailMessageFull] = []
    var events: [CalendarEvent] = []

    init(account: ConnectedAccount, lang: Lang, now: Date) {
        switch account.provider {
        case .microsoft: buildMicrosoft(account: account, lang: lang, now: now)
        case .google: buildGoogle(account: account, lang: lang, now: now)
        }
    }

    // People
    static let me = EmailAddress(name: "Ana García", email: "ana@contoso.com")
    static let laura = EmailAddress(name: "Laura Méndez", email: "laura.mendez@contoso.com")
    static let carlos = EmailAddress(name: "Carlos Ruiz", email: "carlos.ruiz@contoso.com")
    static let sofia = EmailAddress(name: "Sofía Herrera", email: "sofia.herrera@acmelogistics.com")
    static let diego = EmailAddress(name: "Diego Torres", email: "diego.torres@contoso.com")
    static let mariana = EmailAddress(name: "Mariana López", email: "mariana@estudionorte.mx")
    static let gme = EmailAddress(name: "Ana García", email: "demo@gmail.com")
    static let pablo = EmailAddress(name: "Pablo Díaz", email: "pablo.diaz@gmail.com")
    static let lucia = EmailAddress(name: "Lucía Fernández", email: "lucia.fernandez@gmail.com")

    private mutating func mail(_ account: ConnectedAccount, id: String, thread: String? = nil, from: EmailAddress,
                               to: [EmailAddress], cc: [EmailAddress] = [], subject: String, body: String,
                               at date: Date, read: Bool = true, attachments: Bool = false) {
        let firstLine = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(",") && !$0.hasPrefix(">") }
            .prefix(2).joined(separator: " ")
        let link = account.provider == .microsoft
            ? "https://outlook.office.com/mail/inbox/id/\(id)"
            : "https://mail.google.com/mail/u/0/#inbox/\(id)"
        let summary = MailMessageSummary(id: id, threadId: thread ?? id, from: from, to: to, subject: subject,
                                         snippet: String(firstLine.prefix(140)), date: date, isRead: read,
                                         hasAttachments: attachments, webLink: link)
        messages.append(MailMessageFull(summary: summary, cc: cc, bodyText: body))
    }

    private static func ago(_ now: Date, days: Double = 0, hours: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
    }

    /// `days` from today's midnight at `hour:minute` (local time).
    private static func at(_ now: Date, days: Int, hour: Int, minute: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now)) ?? now
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func quoteHeader(_ lang: Lang, _ date: Date, _ who: EmailAddress) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang.en ? "en_US" : "es_MX")
        f.dateFormat = lang.en ? "EEE, MMM d, yyyy 'at' h:mm a" : "EEE, d MMM yyyy 'a las' H:mm"
        return lang.en
            ? "On \(f.string(from: date)), \(who.name ?? "") <\(who.email ?? "")> wrote:"
            : "El \(f.string(from: date)), \(who.name ?? "") <\(who.email ?? "")> escribió:"
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    // MARK: Microsoft (work)

    private mutating func buildMicrosoft(account: ConnectedAccount, lang l: Lang, now: Date) {
        let me = Self.me, laura = Self.laura, carlos = Self.carlos, sofia = Self.sofia, diego = Self.diego, mariana = Self.mariana

        // Thread 1: Acme logistics proposal (3 messages).
        let t1 = "demo-thread-acme"
        let d1 = Self.ago(now, days: 9, hours: 3)
        let b1 = l.t("""
            Hola Ana,

            Te comparto la propuesta de logística para el Q4. Incluye las tres rutas nuevas (Monterrey, Querétaro y Puebla) y el ajuste de tarifas que platicamos.

            Lo importante: si confirmamos antes del 15 de noviembre mantenemos la tarifa actual hasta marzo.

            Quedo atenta,
            Sofía
            """, """
            Hi Ana,

            Here's the Q4 logistics proposal. It covers the three new routes (Monterrey, Querétaro and Puebla) and the rate adjustment we discussed.

            Key point: if we confirm before November 15 we keep the current rate until March.

            Best,
            Sofía
            """)
        mail(account, id: "demo-m01", thread: t1, from: sofia, to: [me], cc: [laura],
             subject: l.t("Propuesta de logística Q4", "Q4 logistics proposal"), body: b1, at: d1, attachments: true)
        let d2 = Self.ago(now, days: 8, hours: 20)
        let b2 = l.t("""
            Gracias, Sofía.

            La revisé con Laura. Nos gusta, pero necesitamos que la ruta de Puebla tenga entregas dos veces por semana, no una. ¿Se puede sin mover la tarifa?

            Saludos,
            Ana
            """, """
            Thanks, Sofía.

            I went through it with Laura. We like it, but the Puebla route needs deliveries twice a week, not once. Can that work without changing the rate?

            Regards,
            Ana
            """) + "\n\n" + Self.quoteHeader(l, d1, sofia) + "\n" + Self.quoted(b1)
        mail(account, id: "demo-m02", thread: t1, from: me, to: [sofia], cc: [laura],
             subject: l.t("RE: Propuesta de logística Q4", "RE: Q4 logistics proposal"), body: b2, at: d2)
        let d3 = Self.ago(now, days: 6, hours: 2)
        let b3 = l.t("""
            Ana, buenas noticias: sí podemos hacer Puebla dos veces por semana con la misma tarifa si el volumen mínimo es de 40 cajas por envío.

            Te mando el contrato actualizado el lunes. ¿Lo vemos en una llamada esta semana?

            Sofía
            """, """
            Ana, good news: we can do Puebla twice a week at the same rate if the minimum volume is 40 boxes per shipment.

            I'll send the updated contract on Monday. Can we go over it on a call this week?

            Sofía
            """) + "\n\n" + Self.quoteHeader(l, d2, me) + "\n" + Self.quoted(b2)
        mail(account, id: "demo-m03", thread: t1, from: sofia, to: [me], cc: [laura],
             subject: l.t("RE: Propuesta de logística Q4", "RE: Q4 logistics proposal"), body: b3, at: d3, read: false)

        // Thread 2: app redesign kickoff (2 messages).
        let t2 = "demo-thread-kickoff"
        let d4 = Self.ago(now, days: 4, hours: 5)
        let b4 = l.t("""
            Equipo,

            Arrancamos el rediseño de la app de clientes. Objetivo: que pedir una reposición tome menos de un minuto.

            Para el kickoff traigan:
            - Las 3 quejas más comunes de soporte (Diego)
            - Los primeros bocetos (Mariana)
            - El presupuesto aprobado (Carlos)

            Laura
            """, """
            Team,

            We're starting the customer app redesign. Goal: reordering should take less than a minute.

            For the kickoff please bring:
            - The top 3 support complaints (Diego)
            - The first sketches (Mariana)
            - The approved budget (Carlos)

            Laura
            """)
        mail(account, id: "demo-m04", thread: t2, from: laura, to: [me, diego, carlos, mariana],
             subject: l.t("Kickoff rediseño de la app", "App redesign kickoff"), body: b4, at: d4)
        let d5 = Self.ago(now, days: 3, hours: 22)
        let b5 = l.t("""
            Perfecto. Yo llevo los bocetos en Figma, son tres direcciones distintas. Les comparto el enlace antes de la reunión.

            Mariana
            """, """
            Great. I'll bring the sketches in Figma, three different directions. I'll share the link before the meeting.

            Mariana
            """) + "\n\n" + Self.quoteHeader(l, d4, laura) + "\n" + Self.quoted(b4)
        mail(account, id: "demo-m05", thread: t2, from: mariana, to: [laura, me, diego, carlos],
             subject: l.t("RE: Kickoff rediseño de la app", "RE: App redesign kickoff"), body: b5, at: d5)

        // Singles.
        mail(account, id: "demo-m06", from: carlos, to: [me],
             subject: l.t("Presupuesto 2027 — primera versión", "2027 budget — first draft"),
             body: l.t("""
                Ana,

                Va la primera versión del presupuesto 2027. Subimos 8% en tecnología y bajamos 5% en eventos. Necesito tus comentarios antes del jueves para llevarlo a dirección.

                Carlos
                """, """
                Ana,

                Here's the first draft of the 2027 budget. Technology goes up 8% and events down 5%. I need your comments before Thursday to take it to leadership.

                Carlos
                """), at: Self.ago(now, days: 7, hours: 4), attachments: true)
        mail(account, id: "demo-m07", from: diego, to: [me],
             subject: l.t("Top 3 quejas de soporte (octubre)", "Top 3 support complaints (October)"),
             body: l.t("""
                Hola Ana, para el kickoff:

                1. No encuentran dónde repetir un pedido anterior (34% de los tickets).
                2. El seguimiento del envío no se actualiza en tiempo real.
                3. Las facturas tardan hasta 48 h en aparecer.

                Diego
                """, """
                Hi Ana, for the kickoff:

                1. People can't find how to repeat a previous order (34% of tickets).
                2. Shipment tracking doesn't update in real time.
                3. Invoices take up to 48 h to show up.

                Diego
                """), at: Self.ago(now, days: 2, hours: 6), read: false)
        mail(account, id: "demo-m08", from: laura, to: [me],
             subject: l.t("¿Movemos la revisión semanal?", "Shall we move the weekly review?"),
             body: l.t("""
                Ana, ¿te late si la revisión semanal pasa a los jueves a las 10? Los lunes se nos junta todo.

                Laura
                """, """
                Ana, would it work for you to move the weekly review to Thursdays at 10? Mondays are too packed.

                Laura
                """), at: Self.ago(now, days: 5, hours: 1))
        mail(account, id: "demo-m09", from: mariana, to: [me],
             subject: l.t("Cotización Estudio Norte", "Estudio Norte quote"),
             body: l.t("""
                Hola Ana,

                Te comparto la cotización del rediseño: 6 semanas, dos rondas de cambios incluidas. Si arrancamos el 3 de noviembre entregamos antes de vacaciones.

                Saludos,
                Mariana López
                Estudio Norte
                """, """
                Hi Ana,

                Here's the quote for the redesign: 6 weeks, two rounds of changes included. If we start on November 3 we deliver before the holidays.

                Best,
                Mariana López
                Estudio Norte
                """), at: Self.ago(now, days: 1, hours: 8), attachments: true)
        mail(account, id: "demo-m10", from: carlos, to: [me, laura],
             subject: l.t("Aprobado: viaje a Monterrey", "Approved: Monterrey trip"),
             body: l.t("""
                Quedó aprobado el viaje a Monterrey para visitar el almacén de Acme. Fechas tentativas: 12 y 13 de noviembre.

                Carlos
                """, """
                The Monterrey trip to visit Acme's warehouse is approved. Tentative dates: November 12 and 13.

                Carlos
                """), at: Self.ago(now, days: 0, hours: 20))
        mail(account, id: "demo-m11", from: sofia, to: [me],
             subject: l.t("Contrato actualizado — Acme Logistics", "Updated contract — Acme Logistics"),
             body: l.t("""
                Ana, adjunto el contrato con las dos entregas semanales a Puebla y el volumen mínimo de 40 cajas. Si te parece bien, lo firmamos en la llamada de mañana.

                Sofía
                """, """
                Ana, attached is the contract with two weekly deliveries to Puebla and the 40-box minimum. If it looks good, we can sign it on tomorrow's call.

                Sofía
                """), at: Self.ago(now, days: 0, hours: 5), read: false, attachments: true)
        mail(account, id: "demo-m12", from: diego, to: [me, laura],
             subject: l.t("Recordatorio: kickoff hoy", "Reminder: kickoff today"),
             body: l.t("""
                Solo para recordar que hoy es el kickoff del rediseño. Ya dejé las quejas de soporte en la carpeta compartida.

                Diego
                """, """
                Just a reminder that the redesign kickoff is today. I left the support complaints in the shared folder.

                Diego
                """), at: Self.ago(now, days: 0, hours: 1.5), read: false)

        // Calendar (8 events: yesterday … +7 days).
        let acc = account.id
        let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ademo-kickoff%40thread.v2/0?context=demo")
        let weekly = "demo-series-weekly"
        events.append(CalendarEvent(
            id: "demo-e1", accountId: acc, seriesId: weekly, title: l.t("Revisión semanal del proyecto", "Weekly project review"),
            start: Self.at(now, days: -1, hour: 10), end: Self.at(now, days: -1, hour: 11),
            location: "Microsoft Teams", joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ademo-weekly"),
            organizer: laura, attendees: [me, laura, carlos],
            notes: l.t("Avances, bloqueos y próximos pasos.", "Progress, blockers and next steps."),
            webLink: "https://outlook.office.com/calendar/item/demo-e1"))
        let kickoffStart = now.addingTimeInterval(-10 * 60)
        events.append(CalendarEvent(
            id: "demo-e2", accountId: acc, title: l.t("Kickoff rediseño de la app", "App redesign kickoff"),
            start: kickoffStart, end: kickoffStart.addingTimeInterval(60 * 60),
            location: "Microsoft Teams", joinURL: teams, organizer: laura, attendees: [me, laura, diego, mariana, carlos],
            notes: l.t("""
                Agenda:
                1. Objetivo: reponer un pedido en menos de un minuto
                2. Quejas de soporte (Diego)
                3. Bocetos (Mariana)
                4. Presupuesto y fechas (Carlos)
                """, """
                Agenda:
                1. Goal: reorder in under a minute
                2. Support complaints (Diego)
                3. Sketches (Mariana)
                4. Budget and dates (Carlos)
                """),
            webLink: "https://outlook.office.com/calendar/item/demo-e2"))
        let oneOnOne = max(Self.at(now, days: 0, hour: 17), now.addingTimeInterval(3 * 3600))
        events.append(CalendarEvent(
            id: "demo-e3", accountId: acc, title: l.t("1:1 con Carlos", "1:1 with Carlos"),
            start: oneOnOne, end: oneOnOne.addingTimeInterval(30 * 60),
            location: l.t("Sala Norte", "North room"), organizer: carlos, attendees: [me, carlos],
            notes: l.t("Comentarios al presupuesto 2027.", "Comments on the 2027 budget."),
            webLink: "https://outlook.office.com/calendar/item/demo-e3"))
        events.append(CalendarEvent(
            id: "demo-e4", accountId: acc, title: l.t("Llamada con Acme Logistics — propuesta Q4", "Call with Acme Logistics — Q4 proposal"),
            start: Self.at(now, days: 1, hour: 9, minute: 30), end: Self.at(now, days: 1, hour: 10, minute: 15),
            location: "Microsoft Teams", joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ademo-acme"),
            organizer: me, attendees: [me, sofia, laura],
            notes: l.t("Revisar el contrato actualizado y firmar si todo está bien.", "Review the updated contract and sign if all is good."),
            webLink: "https://outlook.office.com/calendar/item/demo-e4"))
        events.append(CalendarEvent(
            id: "demo-e5", accountId: acc, title: l.t("Presupuesto 2027", "2027 budget"),
            start: Self.at(now, days: 2, hour: 16), end: Self.at(now, days: 2, hour: 17),
            location: l.t("Sala de consejo", "Board room"), organizer: carlos, attendees: [me, carlos, diego],
            webLink: "https://outlook.office.com/calendar/item/demo-e5"))
        events.append(CalendarEvent(
            id: "demo-e6", accountId: acc, title: l.t("Día de planeación (offsite)", "Planning day (offsite)"),
            start: Self.at(now, days: 3, hour: 0), end: Self.at(now, days: 4, hour: 0), isAllDay: true,
            location: l.t("Casa Lamm, CDMX", "Casa Lamm, Mexico City"), organizer: laura,
            webLink: "https://outlook.office.com/calendar/item/demo-e6"))
        events.append(CalendarEvent(
            id: "demo-e7", accountId: acc, title: l.t("Demo de bocetos con Estudio Norte", "Sketch demo with Estudio Norte"),
            start: Self.at(now, days: 5, hour: 11), end: Self.at(now, days: 5, hour: 12),
            location: "Zoom", joinURL: URL(string: "https://zoom.us/j/5550001234"), organizer: mariana, attendees: [me, mariana, laura],
            notes: l.t("Mariana presenta las tres direcciones de diseño.", "Mariana presents the three design directions."),
            webLink: "https://outlook.office.com/calendar/item/demo-e7"))
        events.append(CalendarEvent(
            id: "demo-e8", accountId: acc, seriesId: weekly, title: l.t("Revisión semanal del proyecto", "Weekly project review"),
            start: Self.at(now, days: 7, hour: 10), end: Self.at(now, days: 7, hour: 11),
            location: "Microsoft Teams", joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ademo-weekly"),
            organizer: laura, attendees: [me, laura, carlos],
            notes: l.t("Avances, bloqueos y próximos pasos.", "Progress, blockers and next steps."),
            webLink: "https://outlook.office.com/calendar/item/demo-e8"))
    }

    // MARK: Google (personal)

    private mutating func buildGoogle(account: ConnectedAccount, lang l: Lang, now: Date) {
        let me = Self.gme, pablo = Self.pablo, lucia = Self.lucia
        let t = "demo-g-thread-cafe"
        let d1 = Self.ago(now, days: 3, hours: 2)
        let b1 = l.t("""
            ¡Ana! ¿Nos vemos esta semana para platicar de la idea de la app de recetas? Tengo un par de ideas para monetizarla.

            Pablo
            """, """
            Ana! Can we meet this week to talk about the recipe app idea? I have a couple of ideas to monetize it.

            Pablo
            """)
        mail(account, id: "demo-g1", thread: t, from: pablo, to: [me], subject: l.t("¿Café esta semana?", "Coffee this week?"), body: b1, at: d1)
        let d2 = Self.ago(now, days: 2, hours: 23)
        mail(account, id: "demo-g2", thread: t, from: me, to: [pablo], subject: l.t("Re: ¿Café esta semana?", "Re: Coffee this week?"),
             body: l.t("¡Va! ¿Mañana a las 8:30 en el de siempre?\n\nAna", "Sure! Tomorrow at 8:30 at the usual place?\n\nAna")
                + "\n\n" + Self.quoteHeader(l, d1, pablo) + "\n" + Self.quoted(b1), at: d2)
        mail(account, id: "demo-g3", from: lucia, to: [me], subject: l.t("Fotos del viaje a Oaxaca", "Photos from the Oaxaca trip"),
             body: l.t("Te dejé las fotos en el álbum compartido. ¡La del mercado quedó increíble!\n\nLucía",
                       "I left the photos in the shared album. The market one turned out amazing!\n\nLucía"),
             at: Self.ago(now, days: 6), attachments: true)
        mail(account, id: "demo-g4", from: pablo, to: [me], subject: l.t("Ideas para la app de recetas", "Recipe app ideas"),
             body: l.t("""
                Como quedamos:
                - Plan gratis con 20 recetas guardadas
                - Plan premium con listas de súper automáticas
                - Alianza con mercados locales

                Pablo
                """, """
                As we said:
                - Free plan with 20 saved recipes
                - Premium plan with automatic grocery lists
                - Partnership with local markets

                Pablo
                """), at: Self.ago(now, days: 0, hours: 9), read: false)

        let acc = account.id
        events.append(CalendarEvent(
            id: "demo-g-e1", accountId: acc, title: l.t("Café con Pablo", "Coffee with Pablo"),
            start: Self.at(now, days: 1, hour: 8, minute: 30), end: Self.at(now, days: 1, hour: 9, minute: 30),
            location: l.t("Café Avellaneda", "Café Avellaneda"), joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            organizer: me, attendees: [me, pablo],
            notes: l.t("Idea de la app de recetas.", "Recipe app idea."),
            webLink: "https://calendar.google.com/calendar/event?eid=demo-g-e1"))
        events.append(CalendarEvent(
            id: "demo-g-e2", accountId: acc, title: l.t("Dentista", "Dentist"),
            start: Self.at(now, days: 4, hour: 18), end: Self.at(now, days: 4, hour: 19),
            location: l.t("Consultorio Dra. Ríos", "Dr. Ríos's office"), organizer: me,
            webLink: "https://calendar.google.com/calendar/event?eid=demo-g-e2"))
    }
}
