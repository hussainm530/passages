import UIKit

/// The reading timer, in the reader, where the reading happens.
///
/// Reps are time-boxed (20/45/90 minutes in the training tracker) but the clock
/// has always lived on another device, so reps went untimed or were reconstructed
/// afterwards from memory. This runs against the rep's target and writes the
/// real elapsed minutes into the Rep Log at the end.
///
/// Design constraint: it must be readable at a glance and invisible the rest of
/// the time. A prominent countdown turns reading into clock-watching, which is
/// the opposite of the point.
final class RepTimerView: UIView {
    private let label = UILabel()
    private let progress = UIView()
    private var progressWidth: NSLayoutConstraint!

    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var timer: Timer?

    /// Seconds subtracted from the *arc* clock by chunk restarts.
    ///
    /// Restarting a chunk rewinds the pacing bar, but must not rewind the rep
    /// log: the log answers "how long did you actually read", and letting a
    /// restart shorten it would quietly falsify the training record. So there
    /// are two clocks -- `elapsed` is the truth and never goes backwards,
    /// `arcElapsed` is the pacing device and does.
    private var rewound: TimeInterval = 0

    /// Whether the timer was running when the app went to the background, so
    /// a deliberate pause survives the screen locking.
    private var resumeOnForeground = false

    /// Target duration in seconds; nil for an untimed read (still counts up).
    var target: TimeInterval?

    /// Seconds spent on this paper in earlier sittings.
    ///
    /// The plan's budget is for the document, not the sitting, so the digits,
    /// the fill and the guide's arc all continue from here rather than from
    /// zero. What the rep log records is `sessionElapsed` -- this sitting alone
    /// -- so carrying time forward on screen never double-counts it in the
    /// training record. Set before `start()`.
    var carried: TimeInterval = 0 {
        didSet {
            // Reaching the target in a previous sitting is old news; announce
            // only a crossing that happens in this one.
            if let t = target, t > 0, carried >= t { announced = true }
            updateLabel()
        }
    }

    /// Fired once when the target is reached. The rep does not stop -- running
    /// over is a legitimate choice, and being ejected from a paper mid-argument
    /// would be worse than the overrun.
    var onTargetReached: (() -> Void)?

    /// Fired every second with the elapsed time, so other views (the guide's
    /// chunk bar) can render against this clock instead of running their own.
    /// Two timers would drift, and the one thing worse than an invisible timer
    /// is two visible ones disagreeing.
    var onTick: ((TimeInterval) -> Void)?

    private var isRunning: Bool { return startedAt != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor(white: 0, alpha: 0.06)
        layer.cornerRadius = 13
        clipsToBounds = true

        // A thin fill behind the digits shows progress toward the target
        // without a second number to read.
        progress.backgroundColor = UIColor(red: 0.54, green: 0.35, blue: 0.17, alpha: 0.16)
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)

        label.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = UIColor(white: 0.25, alpha: 1)
        label.textAlignment = .center
        label.text = "0:00"
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.topAnchor.constraint(equalTo: topAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressWidth,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true

        observeLifecycle()
    }

    // MARK: - Locking

    /// Stop the clock when the screen locks or the cover closes, and start it
    /// again on the way back.
    ///
    /// This is not cosmetic. `elapsed` is derived from a wall-clock `Date`, so
    /// without this a rep interrupted by closing the cover kept counting the
    /// whole time the iPad sat shut -- and a 20-minute rep that took an
    /// afternoon read as a 4-hour one in the training log. The timer stops
    /// firing while suspended either way; what changes here is that the time
    /// spent suspended is not counted.
    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(willResign),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// `willResignActive` rather than `didEnterBackground`: locking the screen
    /// resigns active but does not always background the app promptly, and the
    /// gap is counted time.
    @objc private func willResign() {
        resumeOnForeground = isRunning
        if isRunning { pause() }
    }

    @objc private func didBecomeActive() {
        // Only auto-resume if the lock interrupted a running timer. A timer
        // paused on purpose before putting the iPad down stays paused.
        if resumeOnForeground {
            resumeOnForeground = false
            start()
        }
    }

    // MARK: - Control

    /// Starts counting. Called automatically when a paper opens, because a rep
    /// you have to remember to start is a rep that goes untimed.
    func start() {
        guard !isRunning else { return }
        startedAt = Date()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                     selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        // Keep ticking while the PDF is being scrolled, or the timer freezes
        // during exactly the moments you are actually reading.
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    func pause() {
        guard let started = startedAt else { return }
        accumulated += Date().timeIntervalSince(started)
        startedAt = nil
        timer?.invalidate()
        timer = nil
        updateLabel()
    }

    @objc private func toggle() {
        isRunning ? pause() : start()
    }

    /// This sitting only. The number the rep log is told.
    var sessionElapsed: TimeInterval {
        guard let started = startedAt else { return accumulated }
        return accumulated + Date().timeIntervalSince(started)
    }

    /// Cumulative for the paper: earlier sittings plus this one. What the
    /// digits show and what the target is measured against.
    var elapsed: TimeInterval { return carried + sessionElapsed }

    var elapsedMinutes: Int { return Int((elapsed / 60).rounded()) }

    /// The pacing clock the guide's bars run on. Rewound by a chunk restart;
    /// `elapsed` -- what the rep log records -- is not.
    var arcElapsed: TimeInterval { return max(0, elapsed - rewound) }

    /// Restart the arc clock at `seconds` into the arc, leaving the rep's real
    /// elapsed time untouched.
    func rewindArc(to seconds: TimeInterval) {
        rewound = elapsed - seconds
        announced = false   // the target can be reached again after a restart
        onTick?(arcElapsed)
    }

    // MARK: - Display

    private var announced = false

    @objc private func tick() {
        updateLabel()
        onTick?(arcElapsed)
        guard let target = target, target > 0 else { return }
        let fraction = min(1, elapsed / target)
        progressWidth.constant = bounds.width * CGFloat(fraction)
        if fraction >= 1 && !announced {
            announced = true
            onTargetReached?()
        }
    }

    private func updateLabel() {
        let total = Int(elapsed)
        let text = String(format: "%d:%02d", total / 60, total % 60)
        // Paused state has to be visible, or a timer stopped by accident
        // silently under-reports the rep.
        label.text = isRunning ? text : "❙❙ " + text
        label.alpha = isRunning ? 1 : 0.5
    }
}
