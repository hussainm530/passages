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
            return Store.shared.guideNote(paperKey: self.paper.key,
                                          step: chunk.step)?.text
        }
        // Two sources, deliberately. The stored reference is what will be
        // synced; the directory listing is what is true. They agree in the
        // normal case, and when they disagree it is because a recording exists
        // that no note has claimed -- exactly the case the reader needs told
        // about, so the OR is the honest answer rather than a belt-and-braces.
        guideDrawer.voiceProvider = { [weak self] chunk in
            guard let self = self else { return false }
            if Store.shared.hasVoice(paperKey: self.paper.key, step: chunk.step) {
                return true
            }
            guard let name = Store.shared.guideNote(paperKey: self.paper.key,
                                                    step: chunk.step)?.voiceNote
            else { return false }
            return Store.shared.voiceExists(name)
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
        // Persist the moment audio is captured or removed, not at Save. The
        // reader can leave the paper straight from the composer -- back to the
        // library is one tap, and it tears the composer down without ever
        // reaching Save. Recordings made on that path used to reach the vault
        // with no note pointing at them. `noteChunk` is deliberately left set:
        // this is a mid-edit write, not the end of one.
        composer.onVoiceChange = { [weak self] text, voice in
            guard let self = self, let chunk = self.noteChunk else { return }
            Store.shared.saveGuideNote(paperKey: self.paper.key, step: chunk.step,
                                       chunkTitle: chunk.title, text: text,
                                       voiceNote: voice)
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

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Guide", style: .plain, target: self, action: #selector(toggleGuide))

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
                             step: chunk.step,
                             existing: note?.text ?? "",
                             existingVoice: note?.voiceNote)
    }

    @objc private func toggleGuide() {
        guideDrawer.toggle()
    }

    // MARK: - Annotating

    /// The selection as it stood when the composer opened.
    ///
    /// Held rather than re-read at Save, because `pdfView.currentSelection` is
    /// live and the composer outlives it. A stray tap on the page clears the
    /// selection while the composer is still up; the old code's
    /// `guard let selection = pdfView.currentSelection` at Save then returned
    /// early, so the annotation was dropped with no highlight, no error and no
    /// trace. What the composer quotes is now exactly what gets written.
    private var pendingSelection: PDFSelection?

    @objc private func selectionChanged() {
        guard let selection = pdfView.currentSelection,
              let text = selection.string,
              text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 else {
            return
        }
        // Copy, because PDFKit is free to reuse the object it hands back and
        // the geometry is not read until Save. Copying here rather than
        // computing the line rects here keeps this notification -- which fires
        // throughout a drag -- as cheap as it was.
        pendingSelection = (selection.copy() as? PDFSelection) ?? selection
        composer.present(quote: text)
    }

    /// Writes the annotation locally first, then pushes.
    ///
    /// Order matters: the device is the record of truth. A push that fails
    /// because the ThinkPad is asleep must be invisible to the reader, and the
    /// annotation must still be there tomorrow.
    private func saveAnnotation(comment: String,
                                category: AnnotationCategory?,
                                voice: String?) {
        guard let selection = pendingSelection ?? pdfView.currentSelection,
              let text = selection.string,
              let page = selection.pages.first,
              let document = pdfView.document else { return }

        let pageIndex = document.index(for: page)

        // Per line, not per selection.
        //
        // `selection.bounds(for:)` is the *union* of every glyph the selection
        // touches on that page -- one rectangle whose left edge is the leftmost
        // glyph of any selected line and whose right edge is the rightmost. For
        // anything spanning more than one line that is the full column measure,
        // so the unselected head of the first line and tail of the last were
        // both painted and both recorded as selected. That is the "grabs the
        // whole row in that column" report, and it is why the *geometry* was
        // wrong while `selection.string` was right all along.
        //
        // `selectionsByLine()` (PDFKit, iOS 11+, so safe on the 12.0 target)
        // returns one selection per line holding only the characters actually
        // selected on it. `bounds(for:)` on each of those is tight to that
        // glyph run in x, and the array of them is the staircase.
        var rectsByPage: [Int: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            guard let linePage = line.pages.first else { continue }
            let rect = line.bounds(for: linePage)
            // PDFKit emits degenerate rects at line breaks and for the empty
            // tail of a drag. Drawn they are invisible slivers; stored they are
            // coordinates that point at nothing and can win a tie-break in the
            // vault's placer.
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            rectsByPage[document.index(for: linePage), default: []].append(rect)
        }
        // If nothing usable came back, fall back to the union on the named
        // page: the old, fat shape is worse than the staircase but far better
        // than a record with no geometry and a highlight nobody can see.
        if rectsByPage[pageIndex] == nil {
            rectsByPage[pageIndex] = [selection.bounds(for: page)]
        }

        // Order is PDFKit's own, deliberately not geometric. `selection.string`
        // and `selectionsByLine()` both follow the text stream, so element 0 is
        // the line the quote *starts* on -- which is what the vault's
        // `zotero_annotations.py` needs when it uses `quad_points[0]`'s x to
        // decide which column a repeated phrase sits in. Sorting by (-y, x)
        // would impose top-to-bottom, left-to-right order, interleave the
        // columns of a two-column page, and decouple the first rect from the
        // first words of `text`.
        //
        // Only the named page's rects are stored. A drag across a page break
        // has geometry on both, but the record carries a single `pageIndex`;
        // filing the tail page's coordinates under the head page's number would
        // be actively misleading, since the placer reads them against
        // `page_index`. The highlight itself is still drawn on every page.
        let storedRects = rectsByPage[pageIndex] ?? []

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
            quadPoints: storedRects.map {
                [Double($0.origin.x), Double($0.origin.y),
                 Double($0.width), Double($0.height)]
            }
        )

        Store.shared.add(annotation)
        rep.annotationCount += 1
        Store.shared.updateLatestRep { $0.annotationCount = self.rep.annotationCount }

        drawHighlight(rectsByPage: rectsByPage, in: document,
                      hasComment: !comment.isEmpty || voice != nil)
        pendingSelection = nil
        pdfView.clearSelection()

        // Fire and forget. No spinner, no modal, no leaving the paper --
        // the two frictions this app exists to remove.
        SyncClient.shared.push(annotation)
    }

    /// One `PDFAnnotation` per line rect.
    ///
    /// PDFKit synthesises a highlight's QuadPoints from its `bounds`, so a
    /// single annotation can only ever paint a single rectangle -- which is the
    /// other half of the whole-row bug. N annotations is how the staircase gets
    /// into the file on disk.
    ///
    /// `PDFAnnotation.quadrilateralPoints` would carry the staircase on one
    /// annotation and is also iOS 11+, but its coordinate space (page-relative
    /// vs. annotation-bounds-relative) has differed across PDFKit versions and
    /// there is no Mac in this setup to settle which one iOS 12 wants. Getting
    /// it wrong renders the highlight in the wrong place rather than failing to
    /// build, so it is not worth the trade here.
    private func drawHighlight(rectsByPage: [Int: [CGRect]],
                               in document: PDFDocument,
                               hasComment: Bool) {
        // Colour carries no meaning -- categories come from the comment, per
        // the vault's scheme. Commented highlights are simply darker so they
        // are findable on a re-skim.
        let color = hasComment
            ? UIColor(red: 0.95, green: 0.75, blue: 0.3, alpha: 1)
            : UIColor(red: 0.99, green: 0.9, blue: 0.55, alpha: 1)
        for (index, rects) in rectsByPage {
            guard let page = document.page(at: index) else { continue }
            for rect in rects {
                let highlight = PDFAnnotation(bounds: rect, forType: .highlight,
                                              withProperties: nil)
                highlight.color = color
                page.addAnnotation(highlight)
            }
        }
        // Once, after the whole staircase. `saveDocument()` is a full
        // `document.write(to:)`; left inside the loop, a five-line highlight
        // would rewrite the entire PDF five times on an A7.
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
