import AVFoundation
import AppKit
import SamsungNotesKit
import SwiftUI

/// Records from the microphone and plays a note's recordings.
@MainActor @Observable
final class RecordingDesk: NSObject, AVAudioPlayerDelegate {
    private(set) var isRecording = false
    /// Seconds recorded so far, or played so far of the recording that is playing.
    private(set) var seconds = 0.0
    /// The recording that is playing, by its id.
    private(set) var playing: String?
    var problem: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var file: URL?

    private func tick() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let recorder = self.recorder, recorder.isRecording { self.seconds = recorder.currentTime }
                if let player = self.player, player.isPlaying { self.seconds = player.currentTime }
            }
        }
    }

    /// Starts recording after the Mac has let the app use the microphone.
    func record() {
        guard !isRecording else { return }
        stopPlaying()
        problem = nil
        // Without the sentence that says what the microphone is for, the system ends the app
        // instead of asking: only the bundled app carries it.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            problem = "Recording needs the app as a bundle (build it with bundle.sh): the system asks for the microphone only then."
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard allowed else {
                    self.problem = "\(LocalStore.appName) may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { problem = "Recording could not start."; return }
            self.recorder = recorder
            file = url
            seconds = 0
            isRecording = true
            tick()
        } catch {
            problem = "Recording could not start. \(error.localizedDescription)"
        }
    }

    /// Ends the recording. Returns its file and length, or nil when nothing was recorded.
    func finish() -> (url: URL, seconds: Double)? {
        guard isRecording, let recorder, let file else { return nil }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.file = nil
        isRecording = false
        clock?.invalidate()
        seconds = 0
        guard length >= 0.3 else { try? FileManager.default.removeItem(at: file); return nil }
        return (file, length)
    }

    func cancel() {
        guard let done = finish() else { return }
        try? FileManager.default.removeItem(at: done.url)
    }

    func toggle(_ id: String, file url: URL?) {
        if playing == id { stopPlaying(); return }
        stopPlaying()
        guard let url else { problem = "This recording's file is not on this Mac yet."; return }
        do {
            // The stored file has no extension to go by: the player looks inside it.
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else { problem = "The recording could not be played."; return }
            self.player = player
            playing = id
            seconds = 0
            tick()
        } catch {
            problem = "The recording could not be played. \(error.localizedDescription)"
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        playing = nil
        if !isRecording { clock?.invalidate(); seconds = 0 }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.stopPlaying() } }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(min(max(seconds.rounded(.down), 0), 3_600_000)) : 0
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The note's recordings in a row above its pages, and the recording under way.
struct RecordingsBar: View {
    let session: NoteSession

    var body: some View {
        let desk = session.recordings
        let list = session.note?.document.recordings ?? []
        if desk.isRecording || !list.isEmpty || desk.problem != nil {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if desk.isRecording {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 9, height: 9)
                            Text("Recording  \(RecordingDesk.clock(desk.seconds))").font(.callout.monospacedDigit())
                            Button("Stop") { session.stopRecording() }.buttonStyle(.glassProminent).controlSize(.small)
                            Button("Discard") { desk.cancel() }.controlSize(.small)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .floatingBar()
                        .glassEffect(.regular, in: .capsule)
                    }
                    ForEach(list) { recording in
                        let on = desk.playing == recording.id
                        Button { desk.toggle(recording.id, file: recording.file.flatMap { session.note?.fileURL($0) }) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: on ? "stop.fill" : "play.fill").font(.caption)
                                Text(recording.title.isEmpty ? "Recording" : recording.title).lineLimit(1)
                                Text(RecordingDesk.clock(on ? desk.seconds : recording.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(radius: 16)
                        .floatingBar()
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .contextMenu {
                            if session.canEdit, let file = recording.file { Button("Delete Recording", systemImage: "trash", role: .destructive) { desk.stopPlaying(); session.removeRecording(file) } }
                        }
                        .help(on ? "Stop" : "Play")
                        .accessibilityLabel("\(recording.title.isEmpty ? "Recording" : recording.title), \(RecordingDesk.clock(recording.seconds))")
                    }
                }
                if let problem = desk.problem {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button { desk.problem = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: 560)
                    .floatingBar()
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
        }
    }
}
