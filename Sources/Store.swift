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

    /// When a recording was made, read from its own filename.
    ///
    /// The name is `<paperKey>-<unix seconds>.m4a`, assigned at the moment
    /// recording starts, so it is a more trustworthy timestamp than the file's
    /// mtime -- which a copy or a restore would rewrite.
    func voiceRecordedAt(_ name: String) -> Date? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let digits = name[name.index(after: dash)...]
            .replacingOccurrences(of: ".m4a", with: "")
        guard let seconds = TimeInterval(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Byte size, as a cheap stand-in for "is there anything here".
    func voiceExists(_ name: String) -> Bool {
        return fm.fileExists(atPath: voiceDir.appendingPathComponent(name).path)
    }

    /// Remove a recording the reader has rejected.
    ///
    /// Deliberately deletes the file as well as the reference. The upload
    /// reconciles the whole `voice/` directory against the server, so a file
    /// left behind with no annotation pointing at it would still be uploaded --
    /// and would arrive as audio nothing in the vault could file.
    func deleteVoiceNote(_ name: String) {
        try? fm.removeItem(at: voiceDir.appendingPathComponent(name))
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
