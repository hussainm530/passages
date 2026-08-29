import UIKit

/// Report something about the app, from inside the app.
///
/// Feedback about a reader has always been written down somewhere other than
/// the reader -- a note on the laptop hours later, by which point the specific
/// irritation has flattened into "the composer is fiddly". The complaints that
/// produced this app were only recoverable because they happened to be typed
/// into a reading session; the ones that were not are lost.
///
/// So: one tap from the library, a text box, and it lands in the vault backlog
/// under `## Open` in `_reader-app-feedback.md`, where the next session picks
/// it up. Nothing to file, nothing to route.
///
/// Deliberately not offline-first, unlike annotations. An annotation is the
/// reader's irreplaceable work and must survive a dead tailnet; a note about a
/// button is worth exactly one honest attempt, and pretending otherwise would
/// mean a queue, a flush, and a retry path for the least valuable payload in
/// the app. If it cannot send, it says so and keeps what was typed.
final class FeedbackViewController: UIViewController {

    private let textView = UITextView()
    private let hint = UILabel()
    private let status = UILabel()
    private var sendButton: UIBarButtonItem!

    /// Title of whatever was being read when the observation was made, if any.
    /// The server files it as "While reading: ..." -- context that is obvious
    /// now and unrecoverable in a week.
    var paperContext: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Feedback"
        view.backgroundColor = .white

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        sendButton = UIBarButtonItem(title: "Send", style: .done,
                                     target: self, action: #selector(send))
        sendButton.isEnabled = false
        navigationItem.rightBarButtonItem = sendButton

        hint.text = paperContext.map { "About the app. Reading: \($0)" }
            ?? "About the app — what broke, what annoyed you, what is missing."
        hint.numberOfLines = 0
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .gray
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        textView.font = .systemFont(ofSize: 16)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        status.font = .systemFont(ofSize: 13)
        status.numberOfLines = 0
        status.textColor = .gray
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 180),

            status.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
        ])

        textView.becomeFirstResponder()
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func send() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        sendButton.isEnabled = false
        status.textColor = .gray
        status.text = "Sending…"

        SyncClient.shared.sendFeedback(text: text, paper: paperContext) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.status.text = "Sent."
                self.dismiss(animated: true)
                return
            }
            // Keep the text. Retyping a complaint is how a complaint stops
            // being reported.
            self.sendButton.isEnabled = true
            self.status.textColor = UIColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1)
            self.status.text = "Couldn't reach the laptop — nothing was sent. "
                + "Your text is still here; try again when the tailnet is up."
        }
    }
}

extension FeedbackViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        sendButton.isEnabled = !textView.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
