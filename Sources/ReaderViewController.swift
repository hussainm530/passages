import PDFKit
import UIKit

/// The reading surface. PDFKit renders the same margin-cropped PDF that
/// GoodReader shows, so pagination and the coordinate space are unchanged and
/// annotations still map back to journal pages exactly.
///
/// What is different is everything around the page: the rep timer, the guide
/// drawer, and a composer that captures the real selection.
final class ReaderViewController: UIViewController, PDFViewDelegate {

    private var paper: Paper
    private let pdfView = PDFView()
    private let timerView = RepTimerView()
    private let guideDrawer = GuideDrawer()
    private let composer = CommentComposer()
    private var rep: Rep
    /// The chunk whose response is being written, if any.
    private var noteChunk: GuideChunk?

    init(paper: Paper) {
        self.paper = paper
        self.rep = Rep(paperKey: paper.key, startedAt: Date(),
                       endedAt: nil, annotationCount: 0)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        title = paper.title

        setUpPDFView()
        setUpChrome()

        Store.shared.add(rep)
        // The timer starts on open rather than on a button, because a rep you
        // have to remember to start is a rep that goes untimed.
        timerView.target = paper.repMinutes.map { TimeInterval($0 * 60) }
        timerView.onTargetReached = { [weak self] in self?.announceTarget() }
        // The bar is driven off the same clock as the digits rather than its
        // own timer, so the two can never disagree about how long you've read.
        timerView.onTick = { [weak self] elapsed in
            guard let self = self else { return }
            self.guideDrawer.timerBar.update(elapsed: elapsed)
            let i = self.guideDrawer.timerBar.currentIndex(elapsed: elapsed)
            let all = self.guideDrawer.activeChunks
            self.guideDrawer.setCurrentStep(
                i.flatMap { $0 < all.count ? all[$0].step : nil })
        }
        timerView.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timerView.pause()
        finishRep()
    }

    private func setUpPDFView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = view.backgroundColor ?? .white
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let url = Store.shared.localURL(for: paper)
        if let document = PDFDocument(url: url) {
            pdfView.document = document
            restoreExistingAnnotations(into: document)
            restorePosition()
        } else {
            showMissingFile()
        }
    }

    private func setUpChrome() {
        guideDrawer.install(in: view)
        guideDrawer.configure(paperTitle: paper.title,
                              chunks: paper.chunks ?? [],
                              deepChunks: paper.chunksDeep ?? [],
                              deepIsOn: paper.deepRead ?? false)
        guideDrawer.noteProvider = { [weak self] chunk in
            guard let self = self else { return nil }
            guard let note = Store.shared.guideNote(paperKey: self.paper.key,
                                                    step: chunk.step) else { return nil }
            // Mark audio in the drawer too. A chunk answered only by speaking
            // used to render as an empty note, indistinguishable from one never
            // answered -- so the drawer said "nothing here" about a chunk that
            // had a recording sitting against it.
            guard note.voiceNote != nil else { return note.text }
            return note.text.isEmpty ? "🎙 voice note" : "🎙 " + note.text
        }
        guideDrawer.onDeepChange = { [weak self] on in
            guard let self = self else { return }
            self.paper.deepRead = on
            Store.shared.setDeepRead(paperKey: self.paper.key, deep: on)
            SyncClient.shared.setDeepRead(self.paper, on)
        }
        guideDrawer.onNoteTap = { [weak self] chunk in
            self?.composeNote(for: chunk)
        }
        guideDrawer.timerBar.setChunks(guideDrawer.activeChunks)
        guideDrawer.timerBar.onRestartChunk = { [weak self] index in
            guard let self = self else { return }
            // Rewinds the pacing bar only. The rep log keeps the real elapsed
            // time, so restarting a chunk after an interruption cannot quietly
            // shorten what the training record says you read.
            let start = self.guideDrawer.timerBar.startOfChunk(index)
            self.timerView.rewindArc(to: start)
        }

        composer.install(in: view)
        composer.currentPaperKey = paper.key
        // Ask for the microphone now, not on the first hold. See
        // VoiceRecorder.prepare() -- requesting it inside the gesture is what
        // silently lost every voice note on 18 Aug.
        composer.prepareMicrophone()
        composer.onSave = { [weak self] comment, category, voice in
            self?.saveAnnotation(comment: comment, category: category, voice: voice)
        }
        composer.onSaveNote = { [weak self] text, voice in
            guard let self = self, let chunk = self.noteChunk else { return }
            Store.shared.saveGuideNote(paperKey: self.paper.key, step: chunk.step,
                                       chunkTitle: chunk.title, text: text,
                                       voiceNote: voice)
            self.noteChunk = nil
            self.guideDrawer.refreshNotes()
        }
        // A recording becomes part of the note the moment it stops, not when
        // Save is pressed. Speaking the answer and walking away is the normal
        // way to use this, and it was the one way to lose it: nothing
        // referenced the file, so the drawer showed the chunk unanswered and
        // the vault got audio it could not file.
        //
        // Inert for annotations -- `noteChunk` is nil there, and an annotation
        // has no reopen path where a stranded recording could confuse anyone.
        composer.onVoiceCaptured = { [weak self] name in
            guard let self = self, let chunk = self.noteChunk else { return }
            let existing = Store.shared.guideNote(paperKey: self.paper.key,
                                                  step: chunk.step)
            Store.shared.saveGuideNote(paperKey: self.paper.key, step: chunk.step,
                                       chunkTitle: chunk.title,
                                       text: existing?.text ?? "",
                                       voiceNote: name)
            self.guideDrawer.refreshNotes()
        }

        timerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timerView)
        NSLayoutConstraint.activate([
            timerView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            timerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            timerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])

        // "Guide" stays the primary action; feedback sits beside it because
        // this is where the app is actually being used, and an irritation
        // reported here carries the paper it happened on. Reported from the
        // library twenty minutes later, it arrives as "the composer is fiddly".
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Guide", style: .plain,
                            target: self, action: #selector(toggleGuide)),
            UIBarButtonItem(title: "⚑", style: .plain,
                            target: self, action: #selector(reportIssue))
        ]

        // Selection is watched rather than driven off a menu item, so the
        // composer appears the moment there is something to annotate.
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: .PDFViewSelectionChanged, object: pdfView)
    }

    /// Open the composer against a guide chunk rather than a passage.
    ///
    /// Same window as an annotation deliberately: it is the one input surface
    /// on this device built to survive the keyboard, and a second, lesser text
    /// box for responses would be the thing that stops them being written.
    private func composeNote(for chunk: GuideChunk) {
        noteChunk = chunk
        let note = Store.shared.guideNote(paperKey: paper.key, step: chunk.step)
        composer.presentNote(chunkTitle: "\(chunk.step). \(chunk.title)",
                             existing: note?.text ?? "",
                             existingVoice: note?.voiceNote)
    }

    @objc private func toggleGuide() {
        guideDrawer.toggle()
    }

    /// Feedback about the app, tagged with the paper in hand.
    @objc private func reportIssue() {
        let vc = FeedbackViewController()
        vc.paperContext = paper.title
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    // MARK: - Annotating

    @objc private func selectionChanged() {
        guard let selection = pdfView.currentSelection,
              let text = selection.string,
              text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 else {
            return
        }
        composer.present(quote: text)
    }

    /// Writes the annotation locally first, then pushes.
    ///
    /// Order matters: the device is the record of truth. A push that fails
    /// because the ThinkPad is asleep must be invisible to the reader, and the
    /// annotation must still be there tomorrow.
    /// The selection's geometry, one rectangle per line.
    ///
    /// `selection.bounds(for:)` is the *union* of everything selected, so three
    /// words spanning two lines became a block covering both lines end to end.
    /// In a two-column paper that block is the whole column width, which is
    /// precisely the report: "selecting a passage grabs the whole row in that
    /// column rather than trimming to the selected characters".
    ///
    /// This matters more than it looks. Capturing the *actual* selection is the
    /// reason this app replaced GoodReader -- GoodReader stored a point-anchored
    /// sticky note and discarded the passage, which is why 17 of 20 annotations
    /// had to have their text inferred by hand on 9 Aug 2026. A union box is a
    /// milder version of the same loss.
    ///
    /// `selectionsByLine()` is iOS 11+, so it is inside the 12.0 floor.
    ///
    /// Sorted into reading order rather than trusting the array's order, which
    /// Apple does not document: top line first, then left to right. PDF page
    /// space puts the origin at the *bottom* left and y grows upward, so the
    /// topmost line is the one with the largest y. `zotero_annotations.py` reads
    /// `quad_points[0]` to decide which column a highlight sits in, so element 0
    /// being the first line is load-bearing downstream.
    private func quadPoints(for selection: PDFSelection, on page: PDFPage) -> [[Double]] {
        let lines = selection.selectionsByLine()
            .filter { $0.pages.contains(page) }
            .map { $0.bounds(for: page) }
            // A zero-width or zero-height rect points at nothing, and stored it
            // would still win a tie-break in the vault's placer.
            .filter { $0.width > 0.5 && $0.height > 0.5 }
            .sorted { a, b in
                a.origin.y == b.origin.y ? a.origin.x < b.origin.x
                                         : a.origin.y > b.origin.y
            }

        // Fall back to the union rather than storing nothing. A coarse
        // rectangle still records where the passage was; an empty array loses
        // that. The text itself is captured either way.
        let rects = lines.isEmpty ? [selection.bounds(for: page)] : lines
        return rects.map { [Double($0.origin.x), Double($0.origin.y),
                            Double($0.width), Double($0.height)] }
    }

    private func saveAnnotation(comment: String,
                                category: AnnotationCategory?,
                                voice: String?) {
        guard let selection = pdfView.currentSelection,
              let text = selection.string,
              let page = selection.pages.first,
              let document = pdfView.document else { return }

        let pageIndex = document.index(for: page)
        let quads = quadPoints(for: selection, on: page)

        // A comment-free highlight is General, matching the rule the vault's
        // own pull already applies -- so the common case needs no interaction
        // beyond selecting the text.
        let resolved = category ?? (comment.isEmpty && voice == nil ? .general : nil)

        let annotation = Annotation(
            id: UUID().uuidString,
            paperKey: paper.key,
            pageIndex: pageIndex,
            text: text,
            comment: comment,
            category: resolved,
            voiceNote: voice,
            createdAt: Date(),
            quadPoints: quads
        )

        Store.shared.add(annotation)
        rep.annotationCount += 1
        Store.shared.updateLatestRep { $0.annotationCount = self.rep.annotationCount }

        drawHighlight(quads: quads, on: page, hasComment: !comment.isEmpty || voice != nil)
        pdfView.clearSelection()

        // Fire and forget. No spinner, no modal, no leaving the paper --
        // the two frictions this app exists to remove.
        SyncClient.shared.push(annotation)
    }

    /// One `PDFAnnotation` per line, matching what was actually selected.
    ///
    /// A single annotation over the union rectangle is what made a two-line
    /// selection paint as a block across the whole column. Drawing the same
    /// rectangles that get stored also keeps the burnt-in PDF and the vault's
    /// record of the highlight in agreement, which they were not before.
    private func drawHighlight(quads: [[Double]], on page: PDFPage, hasComment: Bool) {
        // Colour carries no meaning -- categories come from the comment, per
        // the vault's scheme. Commented highlights are simply darker so they
        // are findable on a re-skim.
        let colour = hasComment
            ? UIColor(red: 0.95, green: 0.75, blue: 0.3, alpha: 1)
            : UIColor(red: 0.99, green: 0.9, blue: 0.55, alpha: 1)
        for q in quads where q.count >= 4 {
            let rect = CGRect(x: CGFloat(q[0]), y: CGFloat(q[1]),
                              width: CGFloat(q[2]), height: CGFloat(q[3]))
            let highlight = PDFAnnotation(bounds: rect, forType: .highlight,
                                          withProperties: nil)
            highlight.color = colour
            page.addAnnotation(highlight)
        }
        // Written once, after all of them -- saving per line would rewrite the
        // whole document for every line of a long selection.
        saveDocument()
    }

    /// Persists the PDF itself, so the annotated file is what syncs back to the
    /// Zotero attachment -- same as the GoodReader flow, minus the round trip.
    private func saveDocument() {
        guard let document = pdfView.document else { return }
        document.write(to: Store.shared.localURL(for: paper))
    }

    private func restoreExistingAnnotations(into document: PDFDocument) {
        // Highlights live in the PDF itself once drawn, so nothing to replay.
        // This hook exists for annotations that arrive from the laptop --
        // a paper read partly on the desktop and finished here.
        _ = document
    }

    // MARK: - Rep bookkeeping

    private func finishRep() {
        rep.endedAt = Date()
        Store.shared.updateLatestRep { current in
            current.endedAt = self.rep.endedAt
            current.annotationCount = self.rep.annotationCount
        }
        // Flush on the way out rather than on a button. If the laptop is not
        // reachable, this fails quietly and the next flush picks it up.
        SyncClient.shared.flush()
    }

    private func announceTarget() {
        let banner = UILabel()
        banner.text = "  Target reached — \(timerView.elapsedMinutes) min  "
        banner.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        banner.textColor = .white
        banner.backgroundColor = UIColor(red: 0.54, green: 0.35, blue: 0.17, alpha: 0.95)
        banner.layer.cornerRadius = 14
        banner.clipsToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                        constant: 8),
            banner.heightAnchor.constraint(equalToConstant: 28)
        ])
        // Announce and get out of the way. Running over is a legitimate
        // choice; being interrupted mid-argument by a modal is not.
        UIView.animate(withDuration: 0.3, delay: 3.5, options: [], animations: {
            banner.alpha = 0
        }, completion: { _ in banner.removeFromSuperview() })
    }

    // MARK: - Position

    private var positionKey: String { return "position-" + paper.key }

    private func restorePosition() {
        let saved = UserDefaults.standard.integer(forKey: positionKey)
        guard saved > 0, let document = pdfView.document,
              saved < document.pageCount, let page = document.page(at: saved) else { return }
        pdfView.go(to: page)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        UserDefaults.standard.set(document.index(for: page), forKey: positionKey)
    }

    private func showMissingFile() {
        let label = UILabel()
        label.text = "Not downloaded.\nTap the paper in the library while online."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(white: 0.45, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7)
        ])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
