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
/// Offline-first since 0.8. It was deliberately not -- "a note about a button
/// is worth exactly one honest attempt" -- and the reader's own feedback on
/// 10 Sept 2026 was that the attempt fails often enough, on campus wifi and
/// the train, that the note gets typed and then dropped. It now rides the same
/// unsent-writes queue as reads and offloads: if it cannot send, it is kept on
/// the device and goes on the next sync, and the screen says which happened.
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
            // Not lost: it is in the pending-writes queue and goes with the
            // next sync. Say so, then get out of the way -- the reader was
            // mid-paper.
            self.status.textColor = UIColor(red: 0.72, green: 0.45, blue: 0.0, alpha: 1)
            self.status.text = "Couldn't reach the laptop — saved on the iPad. "
                + "It will go on the next sync."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.dismiss(animated: true)
            }
        }
    }
}

extension FeedbackViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        sendButton.isEnabled = !textView.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
