import UIKit

/// The annotation composer — the part GoodReader gets worst.
///
/// Three fixes to three separate complaints:
///
/// 1. **The keyboard no longer covers it.** The composer is pinned to the
///    keyboard's top edge and moves with it, using the real keyboard frame from
///    the will-change-frame notification. GoodReader's popup does not reflow,
///    so half the field is occluded on a 7.9" screen.
/// 2. **Most annotations need no typing at all.** Category chips are one tap,
///    and a highlight with no comment is General by default — the same rule the
///    vault's pull already uses. Typing is for when there is something to say.
/// 3. **Speaking is a first-class input.** Hold to record; the audio syncs and
///    is transcribed by Moonshine on the laptop.
///
/// It cannot fix swipe typing — third-party keyboards are an OS-level feature
/// and iOS 12 predates QuickPath. It can make typing rarer, which is the part
/// actually within reach.
final class CommentComposer: UIView, UITextViewDelegate {

    private let quoteLabel = UILabel()
    private let textView = UITextView()
    private let chipRow = UIStackView()
    private let micButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let recordingLabel = UILabel()

    private let voiceChip = UIView()
    private let voiceChipLabel = UILabel()
    private let voiceDeleteButton = UIButton(type: .system)
    private lazy var voiceChipHeight: NSLayoutConstraint =
        voiceChip.heightAnchor.constraint(equalToConstant: 0)

    private let recorder = VoiceRecorder()
    private var recordingTimer: Timer?

    private var selectedCategory: AnnotationCategory?
    private var bottomConstraint: NSLayoutConstraint!

    /// Called with the comment, chosen category, and voice-note filename.
    /// Any of them may be empty — a bare highlight is a valid annotation.
    var onSave: ((String, AnnotationCategory?, String?) -> Void)?
    var onCancel: (() -> Void)?

    /// Called instead of `onSave` when the composer was opened for a guide
    /// note. Same window, same keyboard pinning -- a response to the method
    /// deserves the one input surface that was actually designed for typing
    /// on this device.
    var onSaveNote: ((String, String?) -> Void)?
    private var isNoteMode = false

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.97, alpha: 1)
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.86, alpha: 1).cgColor

        // The selected passage, shown so it is obvious what is being annotated.
        // Truncated to two lines: this is confirmation, not re-reading.
        quoteLabel.numberOfLines = 2
        quoteLabel.font = UIFont(name: "Georgia", size: 13) ?? UIFont.systemFont(ofSize: 13)
        quoteLabel.textColor = UIColor(white: 0.42, alpha: 1)
        quoteLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quoteLabel)

        chipRow.axis = .horizontal
        chipRow.spacing = 6
        chipRow.distribution = .fillProportionally
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipRow)
        for category in AnnotationCategory.allCases {
            chipRow.addArrangedSubview(makeChip(category))
        }

        textView.font = UIFont.systemFont(ofSize: 16)
        textView.backgroundColor = .white
        textView.layer.cornerRadius = 8
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor(white: 0.88, alpha: 1).cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        // The attached-recording row. Collapsed to zero height when there is
        // nothing attached, so the composer is unchanged in the common case.
        voiceChip.backgroundColor = UIColor(red: 0.93, green: 0.95, blue: 0.93, alpha: 1)
        voiceChip.layer.cornerRadius = 6
        voiceChip.layer.borderWidth = 1
        voiceChip.layer.borderColor = UIColor(red: 0.72, green: 0.80, blue: 0.74, alpha: 1).cgColor
        voiceChip.clipsToBounds = true
        voiceChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voiceChip)

        voiceChipLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        voiceChipLabel.textColor = UIColor(red: 0.18, green: 0.36, blue: 0.24, alpha: 1)
        voiceChipLabel.translatesAutoresizingMaskIntoConstraints = false
        voiceChip.addSubview(voiceChipLabel)

        voiceDeleteButton.setTitle("Delete", for: .normal)
        voiceDeleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        voiceDeleteButton.setTitleColor(UIColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1),
                                        for: .normal)
        voiceDeleteButton.translatesAutoresizingMaskIntoConstraints = false
        voiceDeleteButton.addTarget(self, action: #selector(deleteVoice), for: .touchUpInside)
        voiceChip.addSubview(voiceDeleteButton)

        micButton.setTitle("🎤  Hold to speak", for: .normal)
        micButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(micButton)
        // Press-and-hold rather than tap-to-toggle: a recording left running
        // by accident is worse than one cut short.
        micButton.addTarget(self, action: #selector(micDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micUp),
                            for: [.touchUpInside, .touchUpOutside, .touchCancel])

        recordingLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        recordingLabel.textColor = UIColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1)
        recordingLabel.isHidden = true
        recordingLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordingLabel)

        saveButton.setTitle("Save", for: .normal)
        saveButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        addSubview(saveButton)

        NSLayoutConstraint.activate([
            quoteLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            quoteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            quoteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            chipRow.topAnchor.constraint(equalTo: quoteLabel.bottomAnchor, constant: 9),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            chipRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chipRow.heightAnchor.constraint(equalToConstant: 30),

            textView.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 9),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textView.heightAnchor.constraint(equalToConstant: 78),

            voiceChip.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            voiceChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            voiceChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            voiceChipHeight,

            voiceChipLabel.leadingAnchor.constraint(equalTo: voiceChip.leadingAnchor,
                                                    constant: 10),
            voiceChipLabel.centerYAnchor.constraint(equalTo: voiceChip.centerYAnchor),
            voiceDeleteButton.trailingAnchor.constraint(equalTo: voiceChip.trailingAnchor,
                                                        constant: -10),
            voiceDeleteButton.centerYAnchor.constraint(equalTo: voiceChip.centerYAnchor),

            micButton.topAnchor.constraint(equalTo: voiceChip.bottomAnchor, constant: 8),
            micButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            micButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            recordingLabel.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            recordingLabel.leadingAnchor.constraint(equalTo: micButton.trailingAnchor,
                                                    constant: 10),

            saveButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])

        observeKeyboard()
    }

    private func makeChip(_ category: AnnotationCategory) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(category.chipLabel, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        b.layer.cornerRadius = 14
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor(white: 0.82, alpha: 1).cgColor
        b.tag = AnnotationCategory.allCases.firstIndex(of: category) ?? 0
        b.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
        return b
    }

    @objc private func chipTapped(_ sender: UIButton) {
        let category = AnnotationCategory.allCases[sender.tag]
        // Tapping the selected chip clears it, so a mis-tap is one tap to undo
        // rather than a wrong category shipped to the vault.
        selectedCategory = (selectedCategory == category) ? nil : category
        refreshChips()
    }

    private func refreshChips() {
        for (i, view) in chipRow.arrangedSubviews.enumerated() {
            guard let b = view as? UIButton else { continue }
            let on = selectedCategory == AnnotationCategory.allCases[i]
            b.backgroundColor = on
                ? UIColor(red: 0.54, green: 0.35, blue: 0.17, alpha: 1) : .clear
            b.setTitleColor(on ? .white : UIColor(white: 0.3, alpha: 1), for: .normal)
        }
    }

    // MARK: - Keyboard avoidance

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// Pins the composer above the keyboard using its actual frame, and matches
    /// the system's own animation curve so it moves *with* the keyboard rather
    /// than chasing it.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let frame = (info[UIResponder.keyboardFrameEndUserInfoKey]
                            as? NSValue)?.cgRectValue,
              let window = window else { return }

        let overlap = max(0, window.bounds.maxY - frame.origin.y)
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey]
                        as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey]
                        as? UInt) ?? 7

        bottomConstraint?.constant = -overlap
        UIView.animate(withDuration: duration, delay: 0,
                       options: UIView.AnimationOptions(rawValue: curveRaw << 16),
                       animations: { self.superview?.layoutIfNeeded() },
                       completion: nil)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        bottomConstraint?.constant = 0
        UIView.animate(withDuration: 0.25) { self.superview?.layoutIfNeeded() }
    }

    // MARK: - Presentation

    func install(in parent: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        bottomConstraint = bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bottomConstraint
        ])
        isHidden = true
    }

    /// Open for a guide-chunk response. Category chips are hidden: a note
    /// about a step of the method has no category to pick, and leaving a
    /// meaningless row of chips on screen invites a meaningless tap.
    ///
    /// `existingVoice` is what makes reopening honest. Until 29 Aug 2026 this
    /// reset the voice state to nil on every open, so a note with a recording
    /// attached looked identical to one without: the reader saw "voice note
    /// attached", navigated away, came back, and had no way to tell whether
    /// anything had been captured -- or to remove a bad take.
    func presentNote(chunkTitle: String, existing: String, existingVoice: String? = nil) {
        isNoteMode = true
        pendingVoiceNote = existingVoice
        recordingLabel.isHidden = true
        quoteLabel.text = chunkTitle
        textView.text = existing
        selectedCategory = nil
        chipRow.isHidden = true
        refreshVoiceChip()
        isHidden = false
        // Unlike an annotation, a note has nothing to save without typing --
        // so here the keyboard *is* raised.
        textView.becomeFirstResponder()
    }

    func present(quote: String) {
        isNoteMode = false
        chipRow.isHidden = false
        pendingVoiceNote = nil
        recordingLabel.isHidden = true
        quoteLabel.text = "“" + quote.trimmingCharacters(in: .whitespacesAndNewlines) + "”"
        textView.text = ""
        selectedCategory = nil
        refreshChips()
        refreshVoiceChip()
        isHidden = false
        // Note: the keyboard is *not* raised automatically. Most annotations
        // are a chip tap or a voice note, and forcing the keyboard up would
        // impose the very friction this is meant to remove.
    }

    func dismiss() {
        textView.resignFirstResponder()
        recorder.cancel()
        stopRecordingUI()
        isHidden = true
    }

    // MARK: - Voice

    /// Prompt for the microphone before it is ever needed.
    func prepareMicrophone() { recorder.prepare() }

    @objc private func micDown() {
        // Say so *before* the hold, rather than leaving a silent no-op. A
        // denied microphone previously looked exactly like a successful
        // recording, which is how 32 annotations came back with no audio.
        if recorder.permission == .denied {
            showMicState("Microphone denied — Settings › Passages › Microphone",
                         bad: true)
            return
        }
        recorder.start(paperKey: currentPaperKey) { started in
            guard started else {
                self.showMicState("Couldn't start recording", bad: true)
                return
            }
            self.recordingLabel.isHidden = false
            self.recordingTimer = Timer.scheduledTimer(
                timeInterval: 0.2, target: self, selector: #selector(self.tickRecording),
                userInfo: nil, repeats: true)
        }
    }

    @objc private func tickRecording() {
        recordingLabel.text = String(format: "● %.1fs", recorder.duration)
    }

    @objc private func micUp() {
        guard recorder.isRecording else {
            // Not a no-op any more. Reaching here means the hold never became
            // a recording, and the reader needs to know that now rather than
            // discovering it on the laptop a day later.
            stopRecordingUI()
            if recorder.permission != .granted {
                showMicState("No microphone access — nothing recorded", bad: true)
            }
            return
        }
        let previous = pendingVoiceNote
        let fresh = recorder.stop()
        stopRecordingUI()
        if let fresh = fresh {
            // One recording per annotation. Replacing means deleting the old
            // file, not just repointing at the new one -- the upload
            // reconciles the whole voice/ directory, so an orphan would still
            // be sent and would arrive as audio nothing can file.
            if let previous = previous, previous != fresh {
                Store.shared.deleteVoiceNote(previous)
            }
            pendingVoiceNote = fresh
            showMicState("✓ voice note attached", bad: false)
        } else {
            showMicState("Too short — nothing recorded", bad: true)
        }
        refreshVoiceChip()
    }

    /// Show what is actually attached, every time the composer opens.
    ///
    /// The old behaviour reported capture only in the moment -- "✓ voice note
    /// attached" -- and that message was gone on reopen. A recording you cannot
    /// see is one you cannot trust or correct, which is how a reader ends up
    /// writing "not sure if voice note captured" in a guide note.
    private func refreshVoiceChip() {
        guard let name = pendingVoiceNote else {
            voiceChipHeight.constant = 0
            voiceChip.isHidden = true
            return
        }
        voiceChip.isHidden = false
        voiceChipHeight.constant = 34

        var parts = ["🎙 voice note"]
        if let at = Store.shared.voiceRecordedAt(name) {
            let f = DateFormatter()
            f.dateFormat = "d MMM, HH:mm"
            parts.append(f.string(from: at))
        }
        // A missing file with a live reference is worth saying out loud rather
        // than rendering as a normal attachment -- it means something removed
        // the audio out from under the note.
        if !Store.shared.voiceExists(name) { parts.append("FILE MISSING") }
        voiceChipLabel.text = parts.joined(separator: "  ·  ")
    }

    /// Remove the attached recording, file and reference together.
    ///
    /// No confirmation dialog: the reader is deleting a take they just judged
    /// bad, usually to record another immediately, and a modal in that loop is
    /// friction with nothing to show for it. The next recording is one hold
    /// away, which is the real undo.
    @objc private func deleteVoice() {
        guard let name = pendingVoiceNote else { return }
        Store.shared.deleteVoiceNote(name)
        pendingVoiceNote = nil
        refreshVoiceChip()
        showMicState("Recording deleted", bad: false)
    }

    /// One place that reports capture state, so it can never be ambiguous.
    /// Stays on screen until the composer is dismissed rather than fading.
    private func showMicState(_ text: String, bad: Bool) {
        recordingLabel.numberOfLines = 2
        recordingLabel.textColor = bad
            ? UIColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1)
            : UIColor(red: 0.18, green: 0.43, blue: 0.31, alpha: 1)
        recordingLabel.text = text
        recordingLabel.isHidden = false
    }

    private func stopRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Save

    var currentPaperKey: String = ""
    private var pendingVoiceNote: String?

    @objc private func save() {
        let comment = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoteMode {
            onSaveNote?(comment, pendingVoiceNote)
        } else {
            onSave?(comment, selectedCategory, pendingVoiceNote)
        }
        pendingVoiceNote = nil
        recordingLabel.isHidden = true
        dismiss()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
