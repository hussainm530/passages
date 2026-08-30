import UIKit

/// The reading guide, as a collapsible drawer over the page.
///
/// The guide (the arc, the target, what to do in each chunk) has always lived
/// in the vault on the other device, which is the entire reason it gets
/// skipped. Splitting attention across two machines is not a workflow.
///
/// It slides in from the trailing edge and overlays rather than reflowing the
/// PDF, because reflowing would change the page layout mid-read -- and page
/// layout is the thing the readability test said to protect.
///
/// It renders the arc from structured chunks rather than parsing markdown, so
/// the timer can segment on the same data the text is drawn from, and each
/// chunk can carry its own response.
final class GuideDrawer: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    let timerBar = ChunkTimerBar()

    private var widthConstraint: NSLayoutConstraint!
    private(set) var isOpen = false

    private var paperTitle = ""
    private var chunks: [GuideChunk] = []
    private var deepChunks: [GuideChunk] = []
    private var deepAvailable = false
    private var deepIsOn = false
    private var currentStep: Int?

    var onDeepChange: ((Bool) -> Void)?
    /// Tapped "add / edit response" on a chunk.
    var onNoteTap: ((GuideChunk) -> Void)?
    /// Looks up the saved response for a chunk, so the drawer can show it
    /// without owning the store.
    var noteProvider: ((GuideChunk) -> String?)?
    /// Whether a chunk has a recording against it. Asked separately from
    /// `noteProvider` rather than folded into the preview string, because the
    /// two answer different questions: one is "what did you write", the other
    /// is "is there audio on this device". A chunk answered only by speaking
    /// used to render exactly like one never answered.
    var voiceProvider: ((GuideChunk) -> Bool)?

    /// Drawer width: wide enough for prose, narrow enough to leave a usable
    /// column of the paper visible on a 7.9" screen in portrait.
    private let openWidth: CGFloat = 300

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 0.97)
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        clipsToBounds = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalToConstant: openWidth - 28)
        ])
    }

    /// Must be called once after the drawer is added to its parent.
    func install(in parent: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            widthConstraint
        ])
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        isOpen = true
        widthConstraint.constant = openWidth
        animate()
    }

    func close() {
        isOpen = false
        widthConstraint.constant = 0
        animate()
    }

    private func animate() {
        UIView.animate(withDuration: 0.24, delay: 0,
                       options: [.curveEaseOut], animations: {
            self.superview?.layoutIfNeeded()
        }, completion: nil)
    }

    // MARK: - Content

    func configure(paperTitle: String, chunks: [GuideChunk],
                   deepChunks: [GuideChunk], deepIsOn: Bool) {
        self.paperTitle = paperTitle
        self.chunks = chunks
        self.deepChunks = deepChunks
        self.deepAvailable = !deepChunks.isEmpty
        self.deepIsOn = deepIsOn
        rebuild()
    }

    /// The arc actually in play, which is what the timer segments on.
    var activeChunks: [GuideChunk] {
        return deepIsOn ? chunks + deepChunks : chunks
    }

    /// Highlight the chunk the clock is in. Called on the timer's tick.
    func setCurrentStep(_ step: Int?) {
        guard step != currentStep else { return }
        currentStep = step
        rebuild()
    }

    /// Re-read one chunk's note after the composer saved it.
    func refreshNotes() { rebuild() }

    @objc private func deepTapped() {
        deepIsOn.toggle()
        onDeepChange?(deepIsOn)
        rebuild()
        timerBar.setChunks(activeChunks)
    }

    @objc private func noteTapped(_ sender: UIButton) {
        let all = activeChunks
        guard sender.tag >= 0 && sender.tag < all.count else { return }
        onNoteTap?(all[sender.tag])
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        stack.addArrangedSubview(makeLabel(paperTitle, size: 15, weight: .semibold,
                                           color: UIColor(white: 0.15, alpha: 1)))

        guard !chunks.isEmpty else {
            stack.addArrangedSubview(makeLabel(
                "No reading guide for this paper. It is not queued as a rep.",
                size: 13, weight: .regular, color: UIColor(white: 0.5, alpha: 1)))
            return
        }

        stack.addArrangedSubview(timerBar)

        // The toggle sits above the arc, not after pass 2: the decision is made
        // at the close of triage, and a control four chunks down is one you
        // won't reach for.
        if deepAvailable { stack.addArrangedSubview(makeDeepToggle()) }

        for (i, chunk) in activeChunks.enumerated() {
            stack.addArrangedSubview(makeChunkCard(chunk, index: i))
        }
    }

    private func makeChunkCard(_ chunk: GuideChunk, index: Int) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = 9
        let isCurrent = currentStep == chunk.step
        card.backgroundColor = isCurrent
            ? UIColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1)
            : UIColor(white: 1, alpha: 0.55)
        card.layer.borderWidth = isCurrent ? 1.5 : 1
        card.layer.borderColor = (isCurrent
            ? UIColor(red: 0.91, green: 0.69, blue: 0.29, alpha: 1)
            : UIColor(white: 0.88, alpha: 1)).cgColor

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 5
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        inner.addArrangedSubview(makeLabel(
            "\(chunk.step). \(chunk.passName) · \(chunk.minutes) min".uppercased(),
            size: 10, weight: .semibold, color: UIColor(white: 0.48, alpha: 1)))
        inner.addArrangedSubview(makeLabel(chunk.title, size: 15, weight: .semibold,
                                           color: UIColor(white: 0.13, alpha: 1)))
        inner.addArrangedSubview(makeLabel(chunk.detail, size: 13, weight: .regular,
                                           color: UIColor(white: 0.28, alpha: 1)))
        for s in chunk.steps {
            inner.addArrangedSubview(makeLabel("•  " + s, size: 12, weight: .regular,
                                               color: UIColor(white: 0.34, alpha: 1)))
        }

        let existing = noteProvider?(chunk) ?? ""
        let hasVoice = voiceProvider?(chunk) ?? false
        let b = UIButton(type: .system)
        b.tag = index
        b.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        b.titleLabel?.numberOfLines = 0
        b.contentHorizontalAlignment = .leading
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        b.layer.cornerRadius = 7
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        if !existing.isEmpty || hasVoice {
            // Showing the response back is the point: a chunk you've answered
            // should look answered, so the arc doubles as a record of the read.
            // Clipped, because a long response overflowed the button instead
            // of ending -- the full text is one tap away in the composer.
            //
            // The 🎙 is the persistent half. It is drawn from the audio the
            // device actually holds, so it is still there after navigating
            // away, after a relaunch, and after a recording that was never
            // saved -- the three ways the old in-the-moment "✓ voice note
            // attached" message vanished and left the reader guessing.
            let flat = existing.replacingOccurrences(of: "\n", with: " ")
            let preview = flat.count > 140
                ? String(flat.prefix(140)).trimmingCharacters(in: .whitespaces) + "…"
                : flat
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            if hasVoice && preview.isEmpty {
                b.setTitle("🎙  Voice note recorded", for: .normal)
            } else {
                b.setTitle((hasVoice ? "🎙🗒  " : "🗒  ") + preview, for: .normal)
            }
            b.setTitleColor(UIColor(white: 0.2, alpha: 1), for: .normal)
            b.backgroundColor = UIColor(red: 0.93, green: 0.95, blue: 0.93, alpha: 1)
        } else {
            b.setTitle("＋  Your response", for: .normal)
            b.setTitleColor(UIColor(white: 0.45, alpha: 1), for: .normal)
            b.backgroundColor = UIColor(white: 0.95, alpha: 1)
        }
        b.addTarget(self, action: #selector(noteTapped(_:)), for: .touchUpInside)
        inner.addArrangedSubview(b)

        return card
    }

    /// A checkbox drawn with text rather than an image set: at this size a box
    /// glyph reads as well as an asset would.
    private func makeDeepToggle() -> UIView {
        let b = UIButton(type: .system)
        b.setTitle((deepIsOn ? "☑︎" : "☐") + "  Deep read — adds pass 3",
                   for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        b.titleLabel?.numberOfLines = 0
        b.contentHorizontalAlignment = .leading
        b.setTitleColor(deepIsOn ? UIColor(red: 0.18, green: 0.43, blue: 0.31, alpha: 1)
                                 : UIColor(white: 0.4, alpha: 1), for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        b.backgroundColor = deepIsOn
            ? UIColor(red: 0.90, green: 0.95, blue: 0.92, alpha: 1)
            : UIColor(white: 0.94, alpha: 1)
        b.layer.cornerRadius = 7
        // 44pt is the documented minimum touch target, and this is reached for
        // with the hand holding the iPad.
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.addTarget(self, action: #selector(deepTapped), for: .touchUpInside)
        return b
    }

    private func makeLabel(_ text: String, size: CGFloat,
                           weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = UIFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }
}
