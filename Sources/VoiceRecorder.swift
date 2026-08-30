import AVFoundation
import Foundation

/// Records a spoken annotation to an m4a in the app's `voice/` directory.
///
/// This is the answer to "typing is a pain" that does not depend on iOS 12
/// ever getting a swipe keyboard. iOS dictation is real-time speech-to-text
/// and is mediocre on this hardware; this deliberately does *not* transcribe.
/// It captures audio and defers transcription to Moonshine on the ThinkPad,
/// which is both far more accurate and impossible to run on an A7.
///
/// The trade-off is honest: the annotation is unreadable until it syncs and is
/// transcribed. For a paragraph of thinking on a train, speaking for twenty
/// seconds beats typing it with two thumbs on a 7.9" screen.
final class VoiceRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var currentFilename: String?

    var isRecording: Bool { return recorder?.isRecording ?? false }

    /// Current microphone permission, without prompting.
    var permission: AVAudioSession.RecordPermission {
        return AVAudioSession.sharedInstance().recordPermission
    }

    /// Ask for the microphone *before* the first press-and-hold.
    ///
    /// This is the bug that lost every voice note on 18 Aug: permission was
    /// requested inside the touch-down handler, so the very first hold raised
    /// the system alert instead of recording. By the time the alert was
    /// answered the finger was long off the button, touch-up had already run,
    /// and `stop()` found nothing to stop. Silently. Prompting when the reader
    /// opens means the alert can never race the gesture.
    func prepare() {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .undetermined else { return }
        session.requestRecordPermission { _ in }
    }

    /// Elapsed seconds, for the level/duration readout while recording.
    var duration: TimeInterval { return recorder?.currentTime ?? 0 }

    /// Requests permission if needed, then starts. `completion` reports whether
    /// recording actually began -- a denied microphone must not look like a
    /// silent successful recording.
    ///
    /// `tag` is an optional anchor written into the filename -- `"s3"` for a
    /// response to chunk 3 of the guide. See `beginRecording` for why the
    /// filename, rather than a stored reference, is where that belongs.
    func start(paperKey: String, tag: String? = nil,
               completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion(false)
                    return
                }
                completion(self.beginRecording(paperKey: paperKey, tag: tag,
                                               session: session))
            }
        }
    }

    private func beginRecording(paperKey: String, tag: String?,
                                session: AVAudioSession) -> Bool {
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            return false
        }

        // Named by paper, anchor and timestamp, so the file *is* the record of
        // what was recorded and what it answers.
        //
        //     <paperKey>-s<step>-<epoch>.m4a   a response to a guide chunk
        //     <paperKey>-<epoch>.m4a           an annotation, as before
        //
        // The step went into the name on 30 Aug 2026 because every other way of
        // knowing a chunk had been spoken to could drift out of step with the
        // audio. `GuideNote.voiceNote` is written only when the reader taps
        // Save; record and then walk away, and the .m4a is on disk with nothing
        // pointing at it. That is not hypothetical -- it is why 19 recordings
        // reached the vault where 13 were expected, six of them attached to
        // nothing. A directory listing cannot drift, but only if the filename
        // says which chunk it belongs to.
        //
        // Nothing on the server side parses the middle of this name:
        // reader_server's _store_voice is name-agnostic past `.m4a`, and
        // voice_transcribe's recorded_at takes the *last* dash-segment, which
        // is still the epoch. Verified by reading, not by running.
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = tag.map { "-\($0)" } ?? ""
        let name = "\(paperKey)\(suffix)-\(stamp).m4a"
        let url = Store.shared.voiceDir.appendingPathComponent(name)

        // Mono 22 kHz AAC: speech-grade, and small enough that a long offline
        // stretch of voice notes is still a trivial upload.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return false }
            recorder = r
            currentFilename = name
            return true
        } catch {
            return false
        }
    }

    /// Stops and returns the filename, or nil if nothing usable was captured.
    @discardableResult
    func stop() -> String? {
        guard let r = recorder else { return nil }
        let tooShort = r.currentTime < 0.6
        r.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)

        let name = currentFilename
        currentFilename = nil

        // A stray tap should not leave an empty file for the laptop to
        // transcribe into nothing.
        if tooShort, let name = name {
            try? FileManager.default.removeItem(
                at: Store.shared.voiceDir.appendingPathComponent(name))
            return nil
        }
        return name
    }

    func cancel() {
        guard let r = recorder, let name = currentFilename else { return }
        r.stop()
        recorder = nil
        currentFilename = nil
        try? FileManager.default.removeItem(
            at: Store.shared.voiceDir.appendingPathComponent(name))
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
