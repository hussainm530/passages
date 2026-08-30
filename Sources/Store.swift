import Foundation

/// On-device storage. The whole reason for going native rather than PWA.
///
/// Everything lives in the app's Documents directory: a real filesystem that
/// iOS does not evict, unlike the Cache/IndexedDB storage a web app would have
/// had to trust. Annotations made on a train with no signal are as durable as
/// ones made at the desk, and the app is fully usable with the ThinkPad
/// switched off. Sync is a background convenience, never a precondition.
final class Store {
    static let shared = Store()

    private let fm = FileManager.default
    private let root: URL
    let pdfDir: URL
    let voiceDir: URL
    private let annotationsFile: URL
    private let papersFile: URL
    private let repsFile: URL
    private let deepReadsFile: URL
    private let guideNotesFile: URL
    private let readFile: URL

    private(set) var papers: [Paper] = []
    private(set) var annotations: [Annotation] = []
    private(set) var reps: [Rep] = []
    /// Paper key -> deep-read flag. Kept in its own file rather than only on
    /// the Paper records, because papers.json is replaced wholesale on every
    /// library refresh and this must survive that.
    private var deepReads: [String: Bool] = [:]
    private(set) var guideNotes: [GuideNote] = []
    /// Paper key -> read. Its own file for the same reason deep-reads are:
    /// papers.json is replaced wholesale on every library refresh.
    private var readFlags: [String: Bool] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pdfDir = root.appendingPathComponent("papers", isDirectory: true)
        voiceDir = root.appendingPathComponent("voice", isDirectory: true)
        annotationsFile = root.appendingPathComponent("annotations.json")
        papersFile = root.appendingPathComponent("papers.json")
        repsFile = root.appendingPathComponent("reps.json")
        deepReadsFile = root.appendingPathComponent("deep_reads.json")
        guideNotesFile = root.appendingPathComponent("guide_notes.json")
        readFile = root.appendingPathComponent("read.json")

        for dir in [pdfDir, voiceDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
        // Read the voice directory once at launch. This is what makes the
        // recording indicator survive a relaunch without anything having been
        // persisted about it: the files are the state.
        rescanVoice()
    }

    // MARK: - Loading

    private func load() {
        papers = decodeFile(papersFile) ?? []
        annotations = decodeFile(annotationsFile) ?? []
        reps = decodeFile(repsFile) ?? []
        deepReads = decodeFile(deepReadsFile) ?? [:]
        guideNotes = decodeFile(guideNotesFile) ?? []
        readFlags = decodeFile(readFile) ?? [:]
    }

    private func decodeFile<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        // Atomic, because the alternative is a truncated annotations file
        // after a mid-write crash -- and annotations are the one thing here
        // that cannot be regenerated from the laptop.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Papers

    func setPapers(_ new: [Paper]) {
        // Locally-set deep-read flags win over whatever the fetch carried:
        // the toggle lives in the reader, and a refresh landing while the
        // laptop hasn't caught up would otherwise silently undo it.
        papers = applyLocalDeepReads(new)
        write(papers, to: papersFile)
    }

    /// Persist a deep-read choice locally.
    ///
    /// The device is the authority here, not the laptop. A `setPapers` from a
    /// sync would otherwise overwrite a flag the reader had just set from the
    /// drawer -- so the local value is re-applied after every refresh, and the
    /// laptop's copy is a mirror rather than the source.
    func setDeepRead(paperKey: String, deep: Bool) {
        deepReads[paperKey] = deep
        write(deepReads, to: deepReadsFile)
        if let i = papers.firstIndex(where: { $0.key == paperKey }) {
            papers[i].deepRead = deep
            write(papers, to: papersFile)
        }
    }

    /// Re-apply locally-set deep-read flags over a freshly fetched library.
    func applyLocalDeepReads(_ fetched: [Paper]) -> [Paper] {
        return fetched.map { paper in
            guard let local = deepReads[paper.key] else { return paper }
            var copy = paper
            copy.deepRead = local
            return copy
        }
    }

    func localURL(for paper: Paper) -> URL {
        return pdfDir.appendingPathComponent(paper.filename)
    }

    func isDownloaded(_ paper: Paper) -> Bool {
        return fm.fileExists(atPath: localURL(for: paper).path)
    }

    // MARK: - Read and offload

    func isRead(_ paperKey: String) -> Bool { return readFlags[paperKey] ?? false }

    /// Marking read is a human claim, made deliberately. It is deliberately
    /// *not* inferred from offloading or from annotation count -- a paper can
    /// be annotated heavily and not finished, or read closely and not marked
    /// up at all.
    func setRead(_ paperKey: String, _ read: Bool) {
        readFlags[paperKey] = read
        write(readFlags, to: readFile)
    }

    /// Delete the local PDF. Annotations, guide notes and the read flag all
    /// stay: offloading frees space, it does not discard the work.
    func offload(_ paper: Paper) {
        try? fm.removeItem(at: localURL(for: paper))
    }

    // MARK: - Guide notes

    func guideNote(paperKey: String, step: Int) -> GuideNote? {
        return guideNotes.first { $0.paperKey == paperKey && $0.step == step }
    }

    /// One note per chunk, edited in place. A chunk has a single response, so
    /// writing again is a correction rather than a second note -- which is also
    /// why `updatedAt` moves and `createdAt` does not.
    func saveGuideNote(paperKey: String, step: Int, chunkTitle: String,
                       text: String, voiceNote: String?) {
        if let i = guideNotes.firstIndex(where: {
            $0.paperKey == paperKey && $0.step == step }) {
            if text.isEmpty && voiceNote == nil {
                guideNotes.remove(at: i)
            } else {
                guideNotes[i].text = text
                // Assign unconditionally. This used to be `if voiceNote != nil`,
                // which made a recording permanently unremovable: nil meant
                // "leave it alone", so there was no way to express "delete the
                // one I attached". The composer now always passes back what it
                // is holding -- the existing filename if untouched, nil if the
                // reader deleted it -- so this is the honest write.
                guideNotes[i].voiceNote = voiceNote
                guideNotes[i].updatedAt = Date()
            }
        } else if !text.isEmpty || voiceNote != nil {
            guideNotes.append(GuideNote(
                id: UUID().uuidString, paperKey: paperKey, step: step,
                chunkTitle: chunkTitle, text: text, voiceNote: voiceNote,
                createdAt: Date(), updatedAt: Date()))
        }
        write(guideNotes, to: guideNotesFile)
    }

    // MARK: - Voice files

    /// The `voice/` directory, as of the last `rescanVoice()`.
    ///
    /// Held in memory because the guide drawer asks "does this chunk have a
    /// recording" once per chunk on every rebuild, and rebuild runs on every
    /// chunk boundary the timer crosses. One listing per mutation is cheap;
    /// nine directory reads per tick is not.
    private var voiceIndex: [String] = []

    /// Re-read `voice/` from disk. Call after anything that adds or removes a
    /// recording -- including `VoiceRecorder`, which deletes too-short takes
    /// behind the Store's back.
    ///
    /// Zero-length files are excluded. An AVAudioRecorder interrupted at the
    /// wrong moment leaves an empty `.m4a`, and reporting that as an
    /// attachment would be the same lie this whole indicator exists to stop
    /// telling.
    func rescanVoice() {
        let all = (try? fm.contentsOfDirectory(atPath: voiceDir.path)) ?? []
        voiceIndex = all
            .filter { $0.lowercased().hasSuffix(".m4a") && (voiceSize($0) ?? 0) > 0 }
            .sorted()
    }

    /// Recordings made against one chunk of the guide, oldest first.
    ///
    /// The trailing hyphen in the prefix is load-bearing: without it `s1`
    /// matches `s10` through `s19`, and step 1 would claim pass 3's audio.
    ///
    /// Sorting the names sorts them by time, because the epoch is fixed-width
    /// until November 2033.
    func voiceNotes(paperKey: String, step: Int) -> [String] {
        let prefix = "\(paperKey)-s\(step)-"
        return voiceIndex.filter { $0.hasPrefix(prefix) }
    }

    /// Whether a chunk has audio on disk, regardless of what any note says.
    ///
    /// This is the durable half of the indicator. `GuideNote.voiceNote` is
    /// written only when the reader taps Save, so it answers "was a response
    /// filed"; this answers "was something recorded", which is the question
    /// actually being asked when the reader looks at the drawer and wonders
    /// whether they spoke to a chunk already.
    func hasVoice(paperKey: String, step: Int) -> Bool {
        return !voiceNotes(paperKey: paperKey, step: step).isEmpty
    }

    /// When a recording was made, read from its own filename.
    ///
    /// The name ends `-<unix seconds>.m4a`, assigned at the moment recording
    /// starts, so it is a more trustworthy timestamp than the file's mtime --
    /// which a copy or a restore would rewrite.
    func voiceRecordedAt(_ name: String) -> Date? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let digits = name[name.index(after: dash)...]
            .replacingOccurrences(of: ".m4a", with: "")
        guard let seconds = TimeInterval(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Bytes on disk, or nil when the file is not there.
    func voiceSize(_ name: String) -> Int? {
        let path = voiceDir.appendingPathComponent(name).path
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Is there actually audio behind this reference?
    func voiceExists(_ name: String) -> Bool {
        return (voiceSize(name) ?? 0) > 0
    }

    /// Remove a recording the reader has rejected -- file *and* every reference
    /// to it.
    ///
    /// Both halves matter, for different reasons. Deleting the file matters
    /// because the upload reconciles the whole `voice/` directory against the
    /// server, so a file left behind with nothing pointing at it would still be
    /// sent and would arrive as audio nothing in the vault could file. Clearing
    /// the references matters because the earlier version deleted only the
    /// file, and a note left pointing at a deleted recording is a second way
    /// for the indicator to lie -- this one claiming audio that no longer
    /// exists.
    func deleteVoiceNote(_ name: String) {
        try? fm.removeItem(at: voiceDir.appendingPathComponent(name))

        var clearedNote = false
        for i in guideNotes.indices where guideNotes[i].voiceNote == name {
            guideNotes[i].voiceNote = nil
            guideNotes[i].updatedAt = Date()
            clearedNote = true
        }
        if clearedNote {
            // A note that existed only to carry the recording has nothing left
            // to be -- the same rule saveGuideNote applies when text is cleared.
            guideNotes.removeAll { $0.text.isEmpty && $0.voiceNote == nil }
            write(guideNotes, to: guideNotesFile)
        }

        var clearedAnnotation = false
        for i in annotations.indices where annotations[i].voiceNote == name {
            annotations[i].voiceNote = nil
            clearedAnnotation = true
        }
        if clearedAnnotation { write(annotations, to: annotationsFile) }

        rescanVoice()
    }

    // MARK: - Annotations

    func annotations(for paperKey: String) -> [Annotation] {
        return annotations
            .filter { $0.paperKey == paperKey }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        write(annotations, to: annotationsFile)
    }

    func update(_ annotation: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[i] = annotation
        write(annotations, to: annotationsFile)
    }

    func delete(id: String) {
        annotations.removeAll { $0.id == id }
        write(annotations, to: annotationsFile)
    }

    // MARK: - Reps

    func add(_ rep: Rep) {
        reps.append(rep)
        write(reps, to: repsFile)
    }

    func updateLatestRep(_ transform: (inout Rep) -> Void) {
        guard !reps.isEmpty else { return }
        transform(&reps[reps.count - 1])
        write(reps, to: repsFile)
    }

    /// Everything the laptop has not yet acknowledged.
    ///
    /// The unsynced set is derived rather than tracked with a dirty flag, so a
    /// failed or half-finished sync cannot silently mark work as delivered.
    func unsynced(since lastSync: Date?) -> (annotations: [Annotation], reps: [Rep]) {
        guard let last = lastSync else { return (annotations, reps) }
        return (annotations.filter { $0.createdAt > last },
                reps.filter { $0.startedAt > last })
    }
}
