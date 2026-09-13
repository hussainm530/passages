import Foundation

/// A paper in the reading queue.
///
/// `key` is the Zotero item key -- the same eight-character key that appears in
/// the staged filename. It is the join between this app, the Zotero library,
/// and the literature note, so it must survive every round trip untouched.
struct Paper: Codable {
    let key: String
    let title: String
    let filename: String
    /// Journal page of PDF page 1, so citations come out right. Mirrors
    /// `page_offset` in the staging state file.
    let pageOffset: Int
    /// Why this paper, what to look for -- rendered in the guide drawer.
    /// Comes from the reading plan; empty when the paper is not part of a rep.
    let guideMarkdown: String
    /// Minutes the rep is meant to last, if this paper is queued as one.
    let repMinutes: Int?
    /// Pass 3's chunks, shipped alongside the guide rather than baked into it.
    /// Held so the drawer's deep-read checkbox can add and remove them with no
    /// round trip -- the decision is made mid-paper, which is exactly when the
    /// network is least likely to be there.
    let guideDeep: String?
    /// Whether this paper is currently marked for a deep read. Persisted on
    /// the laptop; the local value wins until a sync says otherwise.
    var deepRead: Bool?
    /// The reading plan's own name for this paper, so the toggle can be sent
    /// without the app knowing how the plan spells its filenames.
    let planPaper: String?
    /// The arc as data rather than prose: what segments the timer, what the
    /// drawer draws, and what a note gets attached to.
    let chunks: [GuideChunk]?
    /// Pass 3's chunks, appended when the deep-read box is ticked.
    let chunksDeep: [GuideChunk]?
    /// The reading plan's week, used as the library's one level of hierarchy.
    let group: String?

    enum CodingKeys: String, CodingKey {
        case key, title, filename, chunks
        case pageOffset = "page_offset"
        case guideMarkdown = "guide"
        case repMinutes = "rep_minutes"
        case guideDeep = "guide_deep"
        case deepRead = "deep_read"
        case planPaper = "plan_paper"
        case chunksDeep = "chunks_deep"
        case group
    }
}

/// One step of the reading arc: triage, or one 15-minute pass-2/3 chunk.
struct GuideChunk: Codable {
    let step: Int
    let pass: Int
    let passName: String
    let title: String
    let detail: String
    /// Triage's four internal moves; empty for the chunked passes.
    let steps: [String]
    let minutes: Int

    enum CodingKeys: String, CodingKey {
        case step, pass, title, detail, steps, minutes
        case passName = "pass_name"
    }
}

/// A response written against one chunk of the guide.
///
/// Kept apart from `Annotation` deliberately: an annotation is anchored to a
/// passage of the paper, and this is anchored to a step of the *method*. They
/// answer different questions and land in different places in the vault, so
/// merging them to save a type would lose that.
struct GuideNote: Codable {
    let id: String
    let paperKey: String
    let step: Int
    let chunkTitle: String
    var text: String
    var voiceNote: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, step, text
        case paperKey = "paper_key"
        case chunkTitle = "chunk_title"
        case voiceNote = "voice_note"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Categories match the vault's own scheme, so the pull needs no translation
/// step. Chosen by tapping a chip -- the point is that most annotations should
/// need no typing at all.
/// Order is the chip order, left to right, and General leads because it is the
/// default for an untyped highlight.
///
/// Quote was removed in Aug 2026: every annotation stores the actual selected
/// passage, so *all* of them are quotes and the category sorted nothing.
/// Argument replaced the gap it left -- for a passage that is neither a result
/// nor a method, but carries the paper's case.
enum AnnotationCategory: String, Codable, CaseIterable {
    case general = "General"
    case argument = "Argument"
    case finding = "Finding"
    case methodology = "Methodology"
    case critique = "Critique"

    var chipLabel: String {
        switch self {
        case .general: return "General"
        case .argument: return "Argument"
        case .finding: return "Finding"
        case .methodology: return "Method"
        case .critique: return "Critique"
        }
    }
}

/// One highlight, plus whatever the reader had to say about it.
///
/// This is the record GoodReader could not keep: `text` is the *actual*
/// selection, captured at the moment of highlighting. GoodReader stores a
/// point-anchored sticky note and discards the selection, which is why 17 of 20
/// annotations had to have their passage inferred on 9 Aug.
struct Annotation: Codable {
    let id: String
    let paperKey: String
    /// Zero-based PDF page index. The journal page is derived with the
    /// paper's `pageOffset` at write time, never stored pre-adjusted.
    let pageIndex: Int
    let text: String
    var comment: String
    var category: AnnotationCategory?
    /// Filename of a recorded voice note in the app's `voice/` directory,
    /// awaiting transcription on the laptop.
    var voiceNote: String?
    let createdAt: Date
    /// Selection rectangles in PDF page space, so the highlight can be
    /// reconstructed exactly when it is written back into the PDF.
    ///
    /// **One entry per line of the selection**, `[x, y, width, height]`, in
    /// reading order — topmost line first. Until 30 Aug 2026 this was a single
    /// union rectangle covering everything selected, which in a two-column
    /// paper meant a two-line selection painted as a block across the whole
    /// column.
    ///
    /// **PDF page space: the origin is the bottom left and y grows upward**, so
    /// `y` is the rectangle's *bottom* edge. Any consumer laying out from the
    /// top must flip it — `top = pageHeight - (y + height)`. The web client
    /// tags its own records `quad_origin: "top-left"` and treats the absence of
    /// that field as "this came from PDFKit", which is what these are.
    let quadPoints: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, text, comment, category
        case paperKey = "paper_key"
        case pageIndex = "page_index"
        case voiceNote = "voice_note"
        case createdAt = "created_at"
        case quadPoints = "quad_points"
    }
}

/// A single timed reading rep, written to the vault's Rep Log.
///
/// The timer exists because reps are time-boxed and the clock currently lives
/// on a different device from the paper, so reps go untimed or get guessed
/// after the fact.
struct Rep: Codable {
    let paperKey: String
    let startedAt: Date
    var endedAt: Date?
    var annotationCount: Int
    /// Seconds the timer actually ran -- pauses and the screen being locked
    /// excluded. `ended_at - started_at` is the wall-clock span and counts
    /// the lunch break; this is what the timer showed. Optional so reps
    /// written by older builds still decode. The vault's rep log prefers
    /// this when present, and the cumulative per-paper clock is built from it.
    var elapsedSeconds: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case paperKey = "paper_key"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case annotationCount = "annotation_count"
        case elapsedSeconds = "elapsed_seconds"
    }
}
