import Foundation
import CallBrainCore
import CallBrainTranscribe

// Dev tool: transcribe a real recording end-to-end (decode → WhisperKit → FluidAudio → CTM → ingest),
// to verify the Phase-3 path live. Usage:
//   cbtranscribe <storePath> <video> [model] [--no-diarize]
// model defaults to "base" (use "tiny" for the fastest first-run download).

@main
struct CBTranscribe {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 3 else {
            FileHandle.standardError.write(Data("usage: cbtranscribe <storePath> <video> [model] [--no-diarize]\n".utf8))
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
}
