import Testing
@testable import CallBrainAppCore

@Suite("MicGate")
struct MicGateTests {
    private let start: UInt64 = 1_000_000_000

    @Test("attack opens immediately and replays pre-roll at original timestamps")
    func testAttackReplaysPreRoll() {
        let gate = MicGate(sampleRate: 10, preRollSeconds: 0.5, hangoverSeconds: 0.6)
        let first = gate.process(buffer([1, 1], at: start), isSpeech: false, forceMuted: false)
        let second = first.gate.process(buffer([2, 2], at: start + 200_000_000), isSpeech: false, forceMuted: false)

        let opened = second.gate.process(buffer([9], at: start + 400_000_000), isSpeech: true, forceMuted: false)

        #expect(first.decision.buffersToEmit.isEmpty)
        #expect(second.decision.buffersToEmit.isEmpty)
        #expect(opened.decision.state == .speaking)
        #expect(opened.decision.buffersToEmit == [
            buffer([1, 1], at: start),
            buffer([2, 2], at: start + 200_000_000),
            buffer([9], at: start + 400_000_000),
        ])
    }

    @Test("hangover keeps mixing after speech and closes after the configured duration")
    func testHangoverKeepsGateOpenBriefly() {
        let gate = MicGate(sampleRate: 10, preRollSeconds: 0.3, hangoverSeconds: 0.6)
        let speech = gate.process(buffer([7], at: start), isSpeech: true, forceMuted: false)
        let firstSilence = speech.gate.process(buffer([1, 1, 1], at: start + 100_000_000), isSpeech: false, forceMuted: false)
        let finalHangover = firstSilence.gate.process(buffer([2, 2, 2], at: start + 400_000_000), isSpeech: false, forceMuted: false)
        let closed = finalHangover.gate.process(buffer([3], at: start + 700_000_000), isSpeech: false, forceMuted: false)

        #expect(speech.decision.buffersToEmit == [buffer([7], at: start)])
        #expect(firstSilence.decision.state == .speaking)
        #expect(firstSilence.decision.buffersToEmit == [buffer([1, 1, 1], at: start + 100_000_000)])
        #expect(finalHangover.decision.state == .silent)
        #expect(finalHangover.decision.buffersToEmit == [buffer([2, 2, 2], at: start + 400_000_000)])
        #expect(closed.decision.state == .silent)
        #expect(closed.decision.buffersToEmit.isEmpty)
    }

    @Test("pre-roll ring keeps only recent closed-gate buffers")
    func testPreRollIsBounded() {
        let gate = MicGate(sampleRate: 10, preRollSeconds: 0.3, hangoverSeconds: 0.6)
        let old = gate.process(buffer([1, 1], at: start), isSpeech: false, forceMuted: false)
        let recent = old.gate.process(buffer([2, 2], at: start + 200_000_000), isSpeech: false, forceMuted: false)
        let opened = recent.gate.process(buffer([9], at: start + 400_000_000), isSpeech: true, forceMuted: false)

        #expect(opened.decision.buffersToEmit == [
            buffer([2, 2], at: start + 200_000_000),
            buffer([9], at: start + 400_000_000),
        ])
    }

    @Test("force mute closes, discards pre-roll, and does not replay muted audio on unmute")
    func testForceMuteDiscardsPreRoll() {
        let gate = MicGate(sampleRate: 10, preRollSeconds: 0.5, hangoverSeconds: 0.6)
        let primed = gate.process(buffer([1, 1], at: start), isSpeech: false, forceMuted: false)
        let muted = primed.gate.process(buffer([8, 8], at: start + 200_000_000), isSpeech: true, forceMuted: true)
        let unmuted = muted.gate.process(buffer([9], at: start + 400_000_000), isSpeech: true, forceMuted: false)

        #expect(muted.decision.state == .muted)
        #expect(muted.decision.buffersToEmit.isEmpty)
        #expect(unmuted.decision.state == .speaking)
        #expect(unmuted.decision.buffersToEmit == [buffer([9], at: start + 400_000_000)])
    }

    @Test("disabled gate always emits and reports off")
    func testDisabledGateAlwaysEmits() {
        let gate = MicGate(gateEnabled: false, sampleRate: 10, preRollSeconds: 0.3, hangoverSeconds: 0.6)
        let silent = gate.process(buffer([1], at: start), isSpeech: false, forceMuted: false)
        let speech = silent.gate.process(buffer([9], at: start + 100_000_000), isSpeech: true, forceMuted: false)

        #expect(silent.decision.state == .off)
        #expect(silent.decision.buffersToEmit == [buffer([1], at: start)])
        #expect(speech.decision.state == .off)
        #expect(speech.decision.buffersToEmit == [buffer([9], at: start + 100_000_000)])
    }

    private func buffer(_ samples: [Int16], at timestampNanos: UInt64) -> MicGateBuffer {
        MicGateBuffer(samples: samples, timestampNanos: timestampNanos)
    }
}
