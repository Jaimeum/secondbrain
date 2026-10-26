import Foundation

/// Human progress/error texts shown to non-technical users ("es" default, "en").
enum Messages {
    nonisolated(unsafe) static var language = "es"
    private static var es: Bool { language != "en" }

    private static func pct(_ f: Double) -> String { "\(Int((min(max(f, 0), 1) * 100).rounded()))%" }

    static func downloadingWhisper(_ f: Double) -> String {
        es ? "Descargando modelo de transcripción… \(pct(f))" : "Downloading transcription model… \(pct(f))"
    }
    static func downloadingSpeakers(_ f: Double) -> String {
        es ? "Descargando modelo para distinguir voces… \(pct(f))" : "Downloading voice model… \(pct(f))"
    }
    static var optimizing: String {
        es ? "Preparando los modelos para tu Mac (solo la primera vez, puede tardar unos minutos)…"
           : "Getting the models ready for your Mac (first time only, this can take a few minutes)…"
    }
    static var ready: String { es ? "Listo" : "Ready" }
    static var loadingModels: String { es ? "Cargando modelos…" : "Loading models…" }
    static var readingAudio: String { es ? "Leyendo el audio…" : "Reading the audio…" }
    static func transcribingMeeting(_ f: Double) -> String {
        es ? "Transcribiendo la reunión… \(pct(f))" : "Transcribing the meeting… \(pct(f))"
    }
    static func identifyingSpeakers(_ f: Double) -> String {
        es ? "Identificando quién habla… \(pct(f))" : "Working out who is speaking… \(pct(f))"
    }
    static func transcribingMic(_ f: Double) -> String {
        es ? "Transcribiendo tu micrófono… \(pct(f))" : "Transcribing your microphone… \(pct(f))"
    }
    static var merging: String { es ? "Ordenando la transcripción…" : "Putting the transcript together…" }
    static var done: String { es ? "Transcripción lista" : "Transcript ready" }
    static var noAudio: String {
        es ? "No se encontró audio en esta grabación." : "No audio was found in this recording."
    }
    static func modelUnavailable(_ name: String) -> String {
        es ? "No se pudo descargar el modelo de transcripción (\(name)). Revisa tu conexión a internet e inténtalo de nuevo."
           : "Couldn't download the transcription model (\(name)). Check your internet connection and try again."
    }
}
