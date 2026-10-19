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

    /// Where you are in the document, as a quantity rather than a number --
    /// the same argument as the chunk timer. Sits along the bottom edge.
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let pageLabel = UILabel()
    private var bookmarkButton: UIBarButtonItem!
    /// Restoring the saved page has to wait until the PDFView has a size;
    /// `go(to:)` in `viewDidLoad` runs against a zero-height view and scrolls
    /// nowhere, which is why "it never remembers my page" was reported as a
    /// missing bookmark. Done once, on the first real layout.
    private var restoredPosition = false

    /// Single tap on a highlight -> its comment. See `highlightTapped`.
    private let highlightTap = UITapGestureRecognizer()

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
        // ...and it continues from where the last sitting left this paper.
        // The plan's minutes are a budget for the document; a 60-minute read
        // done over three evenings is one read, not three that never finish.
        timerView.carried = Store.shared.priorElapsed(for: paper.key)
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
            // Persist this sitting's count as it grows, not only at the end.
            // A rep that ends with the battery dying used to leave `endedAt`
            // nil and contribute nothing to the next sitting's clock.
            let seconds = self.timerView.sessionElapsed
            if Int(seconds) % 30 == 0 {
                Store.shared.updateLatestRep { $0.elapsedSeconds = seconds }
            }
        }
        timerView.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !restoredPosition, pdfView.bounds.height > 0,
              pdfView.document != nil else { return }
        restoredPosition = true
        restorePosition()
        deferToDoubleTaps()
    }

    /// Let PDFView's double-tap zoom win over the highlight tap.
    ///
    /// Without this the first tap of a double-tap on a highlight opens the
    /// comment sheet while the page zooms underneath it. PDFKit installs its
    /// recognizers on internal subviews once the document has laid out, which
    /// is why this runs here and not in `setUpPDFView`.
    private func deferToDoubleTaps() {
        var stack: [UIView] = [pdfView]
        while let v = stack.popLast() {
            for g in v.gestureRecognizers ?? [] {
                if let tap = g as? UITapGestureRecognizer, tap !== highlightTap,
                   tap.numberOfTapsRequired > 1 {
                    highlightTap.require(toFail: tap)
                }
            }
            stack.append(contentsOf: v.subviews)
        }
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
            // Position is restored in viewDidLayoutSubviews, once the view
            // has a height to scroll within.
        } else {
            showMissingFile()
        }

        // Page position along the bottom. Thin, and under the PDF's own
        // scroll indicator, so it reads as part of the page rather than as
        // chrome to be looked at.
        progressBar.progressTintColor = UIColor(red: 0.54, green: 0.35, blue: 0.17, alpha: 0.85)
        progressBar.trackTintColor = UIColor(white: 0, alpha: 0.08)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        pageLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pageLabel.textColor = UIColor(white: 0.35, alpha: 1)
        pageLabel.backgroundColor = UIColor(white: 1, alpha: 0.85)
        pageLabel.layer.cornerRadius = 8
        pageLabel.clipsToBounds = true
        pageLabel.textAlignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)

        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),

            pageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            pageLabel.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -4),
            pageLabel.heightAnchor.constraint(equalToConstant: 18),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged),
            name: .PDFViewPageChanged, object: pdfView)
        pageChanged()

        // Tapping a highlight shows what was said about it. Hit-tested against
        // the stored quad points rather than PDFKit's own annotation-hit
        // notification, which on iOS reliably fires for links and not for
        // highlights -- and the store is the record anyway, not the drawing.
        highlightTap.addTarget(self, action: #selector(highlightTapped(_:)))
        highlightTap.cancelsTouchesInView = false
        highlightTap.delegate = self
        pdfView.addGestureRecognizer(highlightTap)
    }

    /// Keep the bar, the label and the saved position in step with the page.
    @objc private func pageChanged() {
        guard let document = pdfView.document, document.pageCount > 0,
              let page = pdfView.currentPage else {
            progressBar.progress = 0
            pageLabel.text = nil
            return
        }
        let index = document.index(for: page)
        let count = document.pageCount
        progressBar.setProgress(Float(index + 1) / Float(count), animated: false)
        pageLabel.text = "  \(index + 1) / \(count)  "
        // Not before the saved position has been restored: the first page
        // change fires at page one while the document loads, and writing that
        // would overwrite the very position about to be read back.
        if restoredPosition {
            Store.shared.setProgress(paper.key, page: index, pageCount: count)
        }
        refreshBookmarkButton()
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
        bookmarkButton = UIBarButtonItem(title: "🔖", style: .plain,
                                         target: self, action: #selector(bookmarkTapped))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Guide", style: .plain,
                            target: self, action: #selector(toggleGuide)),
            UIBarButtonItem(title: "☰", style: .plain,
                            target: self, action: #selector(showContents)),
            bookmarkButton,
            UIBarButtonItem(title: "⚑", style: .plain,
                            target: self, action: #selector(reportIssue))
        ]
        refreshBookmarkButton()

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

    // MARK: - Contents and bookmark

    /// The PDF's outline, for the textbooks. Papers mostly have none, and
    /// that is said in one line rather than shown as an empty list.
    @objc private func showContents() {
        guard let document = pdfView.document else { return }
        guard OutlineViewController.hasOutline(document) else {
            let alert = UIAlertController(
                title: "No table of contents",
                message: "This PDF carries no outline. The bookmark still works.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        let vc = OutlineViewController(document: document, currentPage: current)
        vc.onSelect = { [weak self] index in self?.goToPage(index) }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func goToPage(_ index: Int) {
        guard let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    /// One bookmark per paper. Tapping it on the bookmarked page removes it;
    /// tapping it anywhere else offers to jump there or move it here. The
    /// saved *position* is separate and automatic -- this is the deliberate
    /// "come back to this" mark, which reading position cannot be because it
    /// moves every time you check a reference.
    @objc private func bookmarkTapped() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        let here = document.index(for: page)
        let existing = Store.shared.bookmark(for: paper.key)

        guard let marked = existing, marked != here else {
            // No bookmark, or the bookmark is this page: toggle.
            Store.shared.setBookmark(paper.key, page: existing == nil ? here : nil)
            refreshBookmarkButton()
            return
        }

        let sheet = UIAlertController(title: "Bookmark on p. \(marked + 1)",
                                      message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Go to p. \(marked + 1)", style: .default) { _ in
            self.goToPage(marked)
        })
        sheet.addAction(UIAlertAction(title: "Move bookmark to p. \(here + 1)",
                                      style: .default) { _ in
            Store.shared.setBookmark(self.paper.key, page: here)
            self.refreshBookmarkButton()
        })
        sheet.addAction(UIAlertAction(title: "Remove bookmark", style: .destructive) { _ in
            Store.shared.setBookmark(self.paper.key, page: nil)
            self.refreshBookmarkButton()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // An action sheet on iPad is a popover and must be anchored, or it
        // throws at presentation time.
        sheet.popoverPresentationController?.barButtonItem = bookmarkButton
        present(sheet, animated: true)
    }

    /// The button says where the bookmark is, and whether you are on it.
    private func refreshBookmarkButton() {
        guard let marked = Store.shared.bookmark(for: paper.key) else {
            bookmarkButton?.title = "🔖"
            return
        }
        var here: Int?
        if let page = pdfView.currentPage, let document = pdfView.document {
            here = document.index(for: page)
        }
        bookmarkButton?.title = here == marked ? "🔖 ●" : "🔖 p.\(marked + 1)"
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
        // Written as an explicit loop rather than a filter/map/sorted chain:
        // the chained version compiled locally in the reviewer's head and made
        // Swift 5's type checker give up on CI with "unable to type-check this
        // expression in reasonable time". Mixed CGFloat/Double inference across
        // four chained closures is exactly what triggers it.
        var lines: [CGRect] = []
        for line in selection.selectionsByLine() {
            guard line.pages.contains(page) else { continue }
            let rect: CGRect = line.bounds(for: page)
            // A zero-width or zero-height rect points at nothing, and stored it
            // would still win a tie-break in the vault's placer.
            if rect.width > 0.5 && rect.height > 0.5 {
                lines.append(rect)
            }
        }

        lines.sort { (a: CGRect, b: CGRect) -> Bool in
            if a.origin.y == b.origin.y { return a.origin.x < b.origin.x }
            return a.origin.y > b.origin.y
        }

        // Fall back to the union rather than storing nothing. A coarse
        // rectangle still records where the passage was; an empty array loses
        // that. The text itself is captured either way.
        if lines.isEmpty {
            lines = [selection.bounds(for: page)]
        }

        var quads: [[Double]] = []
        for rect in lines {
            let x = Double(rect.origin.x)
            let y = Double(rect.origin.y)
            let w = Double(rect.size.width)
            let h = Double(rect.size.height)
            quads.append([x, y, w, h])
        }
        return quads
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
            let x: CGFloat = CGFloat(q[0])
            let y: CGFloat = CGFloat(q[1])
            let w: CGFloat = CGFloat(q[2])
            let h: CGFloat = CGFloat(q[3])
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let highlight = PDFAnnotation(bounds: rect, forType: .highlight,
                                          withProperties: nil)
            highlight.color = colour
            page.addAnnotation(highlight)
        }
        // Not written back into the PDF. Until 0.8 every highlight ended with
        // `document.write(to:)` -- a full rewrite of the file, on the main
        // thread, which on an A7 with a 300-page textbook is the ten-second
        // freeze reported as "save is slow". The burnt-in copy was never used:
        // sync sends JSON, not the PDF, and the vault writes the highlights
        // into Zotero's copy from the stored quad points. So the highlight is
        // drawn in memory now and replayed from annotations.json on open,
        // which also means it survives an offload and a re-download.
    }

    /// Paint the stored highlights back onto the freshly loaded document.
    ///
    /// PDFs annotated by builds before 0.8 already carry their highlights
    /// burnt in; those are detected by bounds and not drawn twice, or every
    /// old highlight would darken on each open.
    private func restoreExistingAnnotations(into document: PDFDocument) {
        let mine = Store.shared.annotations(for: paper.key)
        guard !mine.isEmpty else { return }
        for annotation in mine {
            guard annotation.pageIndex >= 0, annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { continue }
            let hasComment = !annotation.comment.isEmpty || annotation.voiceNote != nil
            let already: [CGRect] = page.annotations
                .filter { $0.type == "Highlight" }
                .map { $0.bounds }
            var missing: [[Double]] = []
            for q in annotation.quadPoints where q.count >= 4 {
                let rect = CGRect(x: CGFloat(q[0]), y: CGFloat(q[1]),
                                  width: CGFloat(q[2]), height: CGFloat(q[3]))
                var found = false
                for b in already {
                    let dx: CGFloat = abs(b.origin.x - rect.origin.x)
                    let dy: CGFloat = abs(b.origin.y - rect.origin.y)
                    let dw: CGFloat = abs(b.size.width - rect.size.width)
                    let dh: CGFloat = abs(b.size.height - rect.size.height)
                    if dx < 1 && dy < 1 && dw < 1 && dh < 1 {
                        found = true
                        break
                    }
                }
                if !found { missing.append(q) }
            }
            if !missing.isEmpty {
                drawHighlight(quads: missing, on: page, hasComment: hasComment)
            }
        }
    }

    // MARK: - Reading back a highlight

    /// Show the comment, category and voice note behind a tapped highlight.
    ///
    /// Read-only on purpose. An edit made here would not reach the vault: the
    /// app only resends annotations *created* since the last sync, and both
    /// `reader_server.py` and `ipad_inbox.py` dedupe by id keeping the first
    /// version seen. Editing needs an `updated_at` carried end to end first --
    /// until then a sheet that offered it would let the device and the
    /// literature note quietly disagree.
    @objc private func highlightTapped(_ gesture: UITapGestureRecognizer) {
        // A tap while text is selected is the reader adjusting or dismissing
        // the selection, not asking about a highlight.
        if let s = pdfView.currentSelection?.string,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }

        let location = gesture.location(in: pdfView)
        guard let document = pdfView.document,
              let page = pdfView.page(for: location, nearest: false) else { return }
        let point = pdfView.convert(location, to: page)
        let index = document.index(for: page)

        // Overlapping highlights: the newest wins, being the one drawn on top.
        var hit: Annotation?
        var hitRect = CGRect.zero
        for annotation in Store.shared.annotations(for: paper.key)
        where annotation.pageIndex == index {
            for q in annotation.quadPoints where q.count >= 4 {
                let rect = CGRect(x: CGFloat(q[0]), y: CGFloat(q[1]),
                                  width: CGFloat(q[2]), height: CGFloat(q[3]))
                // A little slack: a line of text is about a fingertip tall.
                guard rect.insetBy(dx: -3, dy: -3).contains(point) else { continue }
                if hit == nil || annotation.createdAt > hit!.createdAt {
                    hit = annotation
                    hitRect = rect
                }
            }
        }
        guard let annotation = hit else { return }
        let anchor = pdfView.convert(hitRect, from: page)
        showAnnotation(annotation, from: anchor)
    }

    private func showAnnotation(_ annotation: Annotation, from anchor: CGRect) {
        // A half-written new annotation would sit on top of the sheet.
        composer.dismiss()

        let category = annotation.category?.rawValue ?? "Note"
        let journalPage = annotation.pageIndex + 1 + paper.pageOffset
        var quote = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if quote.count > 280 { quote = String(quote.prefix(280)) + "…" }

        var parts = ["“" + quote + "”"]
        parts.append(annotation.comment.isEmpty ? "No comment." : annotation.comment)
        if let voice = annotation.voiceNote {
            var line = "🎙 voice note"
            if let at = Store.shared.voiceRecordedAt(voice) {
                let f = DateFormatter()
                f.dateFormat = "d MMM, HH:mm"
                line += " · " + f.string(from: at)
            }
            if !Store.shared.voiceExists(voice) { line += " · FILE MISSING" }
            parts.append(line)
        }

        let sheet = UIAlertController(title: "\(category) · p. \(journalPage)",
                                      message: parts.joined(separator: "\n\n"),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Done", style: .cancel))
        // An action sheet on iPad is a popover and must be anchored, or it
        // throws at presentation time.
        sheet.popoverPresentationController?.sourceView = pdfView
        sheet.popoverPresentationController?.sourceRect = anchor
        present(sheet, animated: true)
    }

    // MARK: - Rep bookkeeping

    private func finishRep() {
        rep.endedAt = Date()
        rep.elapsedSeconds = timerView.sessionElapsed
        Store.shared.updateLatestRep { current in
            current.endedAt = self.rep.endedAt
            current.annotationCount = self.rep.annotationCount
            // This sitting alone, pauses excluded. Not the cumulative figure
            // on screen -- that would count the earlier sittings twice.
            current.elapsedSeconds = self.rep.elapsedSeconds
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
        // The store is written on every page turn; the UserDefaults key is
        // what builds before 0.8 wrote on the way out, kept so an upgrade
        // does not open every paper at page one.
        let saved = Store.shared.progress(for: paper.key)?.page
            ?? UserDefaults.standard.integer(forKey: positionKey)
        guard saved > 0, let document = pdfView.document,
              saved < document.pageCount, let page = document.page(at: saved) else { return }
        pdfView.go(to: page)
        pageChanged()
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

extension ReaderViewController: UIGestureRecognizerDelegate {
    /// Alongside PDFView's own gestures, never instead of them: selecting text
    /// and scrolling must behave exactly as they did before highlights were
    /// tappable.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}
