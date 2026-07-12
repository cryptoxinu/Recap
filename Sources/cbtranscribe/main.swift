import Foundation
import CallBrainCore
import CallBrainTranscribe

// Dev/helper tool:
//   cbtranscribe --json-output <path> --title <title> [--date YYYY-MM-DD] [--model model] [--no-diarize] <video>
//   cbtranscribe <storePath> <video> [model] [--no-diarize]
// The JSON mode is used by Recap.app as a crash boundary around WhisperKit/CoreML.

@main
struct CBTranscribe {
    static func main() async {
        let a = CommandLine.arguments
        if a.contains("--json-output") {
            await runJSONMode(a)
            return
        }
        if a.contains("--serve") {
            await runServeMode(a)
            return
        }
        guard a.count >= 3 else {
            FileHandle.standardError.write(Data(Self.usage.utf8))
            exit(2)
        }
        let storePath = a[1]
        let url = URL(fileURLWithPath: a[2])
        let model = a.count > 3 && !a[3].hasPrefix("--") ? a[3] : "base"
        let diarize = !a.contains("--no-diarize")

        do {
            let store = try Store(path: storePath)
            let embedder = OllamaEmbedder()
            let ingest = IngestEngine(store: store, embedder: embedder, space: "nomic__v1")

            let pipeline = TranscriptionPipeline(
                transcriber: WhisperKitTranscriber(model: model),
                diarizer: diarize ? FluidAudioDiarizer() : nil)

            FileHandle.standardError.write(Data("transcribing \(url.lastPathComponent) with whisper '\(model)'\(diarize ? " + diarization" : "")…\n".utf8))
            let title = url.deletingPathExtension().lastPathComponent
            let out = try await pipeline.run(url: url, title: title, date: TimeCode.ymd(Date())) { stage, p in
                FileHandle.standardError.write(Data("  [\(stage)] \(Int(p * 100))%\n".utf8))
            }
            let parsed = out.transcript
            FileHandle.standardError.write(Data("transcript: \(parsed.utterances.count) utterances, \(parsed.speakers.count) speaker(s), diarized=\(out.diarizationSucceeded)\n".utf8))
            for u in parsed.utterances.prefix(4) {
                print("  \(u.speakerRaw) [\(Int(u.tStart))s]: \(u.text.prefix(90))")
            }
            let outcome = try await ingest.ingest(parsed)
            print("ingested \(outcome.meetingID): \(outcome.chunkCount) chunks, \(outcome.embedded) embedded")
        } catch {
            FileHandle.standardError.write(Data("transcribe error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static let usage = """
    usage:
      cbtranscribe --json-output <path> --title <title> [--date YYYY-MM-DD] [--model model] [--no-diarize] <video>
      cbtranscribe <storePath> <video> [model] [--no-diarize]
    """

    /// Persistent live-transcription server: load the model ONCE, then transcribe rolling windows
    /// streamed over stdin/stdout (see LiveServeProtocol). Running here — a child process — means a
    /// WhisperKit/CoreML assertion kills THIS process, not Recap.app, mid-meeting. The app
    /// re-spawns on the next tick; the live transcript just skips a window.
    private static func runServeMode(_ args: [String]) async {
        let model = flagValue(after: "--model", in: args) ?? "openai_whisper-base"
        let transcriber = WhisperKitTranscriber(
            model: model,
            fallbacks: ["openai_whisper-base", "openai_whisper-tiny"],
            allowDownload: false,
            unloadAfterEach: false)
        await transcriber.prewarm()
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        FileHandle.standardError.write(Data("live serve ready (\(model))\n".utf8))
        while true {
            guard let header = LiveServeProtocol.readExactly(stdin, 4),
                  let count = LiveServeProtocol.decodeLength(header) else { break }  // EOF → clean exit
            if count == 0 {
                try? stdout.write(contentsOf: LiveServeProtocol.encodeResponse([]))
                continue
            }
            // Bound the request before allocating: a live window is at most a couple of minutes of
            // 16kHz audio. An absurd count is a malformed parent / protocol desync → exit (the app
            // re-spawns), never try to reserve gigabytes.
            guard count <= 16_000 * 120, let body = LiveServeProtocol.readExactly(stdin, count * 4) else { break }
            let samples = LiveServeProtocol.samples(from: body)
            let segments = (try? await transcriber.transcribe(samples, progress: { _ in })) ?? []
            try? stdout.write(contentsOf: LiveServeProtocol.encodeResponse(segments))
        }
    }

    private static func flagValue(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func runJSONMode(_ args: [String]) async {
        do {
            let options = try JSONOptions(arguments: Array(args.dropFirst()))
            let pipeline = TranscriptionPipeline(
                transcriber: WhisperKitTranscriber(
                    model: options.model,
                    fallbacks: ["openai_whisper-base", "openai_whisper-tiny"],
                    allowDownload: false,
                    unloadAfterEach: true
                ),
                diarizer: options.diarize ? FluidAudioDiarizer() : nil)
            FileHandle.standardError.write(
                Data("transcribing \(options.video.lastPathComponent) with whisper '\(options.model)'\(options.diarize ? " + diarization" : "")\n".utf8)
            )
            let out = try await pipeline.run(url: options.video, title: options.title, date: options.date,
                                             systemAudioURL: options.systemAudio, founderName: options.founder) { stage, p in
                FileHandle.standardError.write(Data("  [\(stage)] \(Int(p * 100))%\n".utf8))
            }
            let payload = TranscriptionSidecarPayload(output: out)
            try FileManager.default.createDirectory(
                at: options.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: options.output, options: [.atomic])
        } catch TranscribeError.emptyAudio {
            // No speech in the recording — a distinct, EXPECTED outcome (a silent/failed-mic capture),
            // not a helper crash. Exit 3 so the parent can still create a findable meeting for it
            // instead of dropping the recording as a generic failure (P2c: never lose a recording).
            FileHandle.standardError.write(Data("transcribe error: emptyAudio (no speech)\n".utf8))
            exit(3)
        } catch {
            FileHandle.standardError.write(Data("transcribe error: \(error)\n".utf8))
            exit(1)
        }
    }

    private struct JSONOptions {
        let output: URL
        let video: URL
        let title: String
        let date: String?
        let model: String
        let diarize: Bool
        let systemAudio: URL?
        let founder: String?

        init(arguments: [String]) throws {
            var output: String?
            var title: String?
            var date: String?
            var model = "openai_whisper-large-v3_turbo_954MB"
            var diarize = true
            var systemAudioPath: String?
            var founderName: String?
            var positional: [String] = []
            var index = 0
            while index < arguments.count {
                let arg = arguments[index]
                switch arg {
                case "--json-output":
                    output = try Self.value(after: arg, in: arguments, index: &index)
                case "--title":
                    title = try Self.value(after: arg, in: arguments, index: &index)
                case "--date":
                    date = try Self.value(after: arg, in: arguments, index: &index)
                case "--model":
                    model = try Self.value(after: arg, in: arguments, index: &index)
                case "--system-audio":
                    systemAudioPath = try Self.value(after: arg, in: arguments, index: &index)
                case "--founder":
                    founderName = try Self.value(after: arg, in: arguments, index: &index)
                case "--no-diarize":
                    diarize = false
                    index += 1
                default:
                    positional.append(arg)
                    index += 1
                }
            }
            guard let output, !output.isEmpty,
                  let videoPath = positional.last, !videoPath.isEmpty else {
                throw OptionsError.invalid(CBTranscribe.usage)
            }
            self.output = URL(fileURLWithPath: output)
            self.video = URL(fileURLWithPath: videoPath)
            if let title, !title.isEmpty {
                self.title = title
            } else {
                self.title = self.video.deletingPathExtension().lastPathComponent
            }
            self.date = date
            self.model = model
            self.diarize = diarize
            self.systemAudio = (systemAudioPath?.isEmpty == false) ? URL(fileURLWithPath: systemAudioPath!) : nil
            self.founder = (founderName?.isEmpty == false) ? founderName : nil
        }

        private static func value(after flag: String, in args: [String], index: inout Int) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < args.count else { throw OptionsError.invalid("Missing value after \(flag)") }
            index += 2
            return args[valueIndex]
        }
    }

    private enum OptionsError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self {
            case .invalid(let message): return message
            }
        }
    }
}
