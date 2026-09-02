import UIKit

/// The reading queue. Shows what is on the device versus what is only on the
/// laptop, because that distinction is the whole offline story and hiding it
/// would mean discovering a missing paper on a train.
///
/// Grouped one level deep by the reading plan's week, so it is visible which
/// papers belong together — and so a group can be seen as finished before its
/// papers are pushed off the list.
final class LibraryViewController: UITableViewController {

    /// (group title, papers) in plan order, ungrouped papers last.
    private var sections: [(String, [Paper])] = []
    private var downloading = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reading"
        tableView.rowHeight = 68
        tableView.tableFooterView = buildVersionFooter()

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Sync", style: .plain, target: self, action: #selector(syncNow))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Feedback", style: .plain, target: self, action: #selector(openFeedback))

        rebuildSections()
        refresh()
    }

    /// Report something about the app itself. Reachable from the list rather
    /// than buried behind a settings screen the app does not have.
    @objc private func openFeedback() {
        let vc = FeedbackViewController()
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    /// Version and server host, at the foot of the list.
    ///
    /// This exists because on 29 Aug 2026 a fixed build was sideloaded and
    /// there was no way to tell it apart from the old one -- same icon, same
    /// first screen, and nothing anywhere in the UI naming a version. "It looks
    /// very similar" is not something the person re-signing the app should have
    /// to resolve by testing behaviour.
    ///
    /// The host is here for the same reason: which laptop this build talks to
    /// changed in that release, and it is otherwise invisible.
    private func buildVersionFooter() -> UIView {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let host = SyncClient.shared.baseURL.host ?? "no host"

        let label = UILabel(frame: CGRect(x: 0, y: 0,
                                          width: tableView.bounds.width, height: 44))
        label.text = "Passages \(short) (\(build))  ·  \(host)"
        label.font = .systemFont(ofSize: 12)
        label.textColor = .gray
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth]
        return label
    }

    /// Groups preserve the order the server sent them in, which is plan order.
    /// Sorting alphabetically would put Week 10 before Week 2, and the plan's
    /// sequence is the thing worth preserving anyway.
    private func rebuildSections() {
        var order: [String] = []
        var buckets: [String: [Paper]] = [:]
        for paper in Store.shared.papers {
            let key = paper.group ?? "Not in the reading plan"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(paper)
        }
        sections = order.map { ($0, buckets[$0] ?? []) }
    }

    private func paper(at path: IndexPath) -> Paper {
        return sections[path.section].1[path.row]
    }

    // MARK: - Sync

    @objc private func refresh() {
        // Launch and pull-to-refresh both land here, which makes it the other
        // natural moment to drain writes that never made it out.
        SyncClient.shared.retryPendingWrites()

        SyncClient.shared.fetchLibrary { [weak self] papers in
            guard let self = self else { return }
            self.refreshControl?.endRefreshing()
            self.rebuildSections()
            self.tableView.reloadData()
            // Offline is normal, not an error. The queue on disk still works,
            // so say nothing and carry on.
            _ = papers
        }
    }

    @objc private func syncNow() {
        // Anything that failed to send earlier goes first -- an offload marked
        // while the laptop was asleep is the whole reason this queue exists.
        SyncClient.shared.retryPendingWrites()

        SyncClient.shared.flush { [weak self] ok in
            guard let self = self else { return }
            self.navigationItem.rightBarButtonItem?.title = ok ? "Synced" : "Offline"

            // Then refetch the library. Sync used to only push, so a paper
            // offloaded on this device stayed on the list until you pulled to
            // refresh or relaunched -- it read as "I offloaded it and sync did
            // nothing". The server drops an offloaded paper from /api/library,
            // so one fetch is all it takes for the row to go.
            SyncClient.shared.fetchLibrary { [weak self] _ in
                guard let self = self else { return }
                self.rebuildSections()
                self.tableView.reloadData()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.navigationItem.rightBarButtonItem?.title = "Sync"
            }
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        let (name, papers) = sections[section]
        let read = papers.filter { Store.shared.isRead($0.key) }.count
        // "3 of 4 read" is the whole point of grouping: knowing a week is
        // finished before its papers are cleared off the device.
        return "\(name)  —  \(read) of \(papers.count) read"
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        return sections[section].1.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "paper")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "paper")
        let paper = self.paper(at: indexPath)
        let isRead = Store.shared.isRead(paper.key)

        cell.textLabel?.text = (isRead ? "✓  " : "") + paper.title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.textLabel?.textColor = isRead
            ? UIColor(white: 0.45, alpha: 1) : UIColor(white: 0.1, alpha: 1)

        let count = Store.shared.annotations(for: paper.key).count
        var parts: [String] = []
        if downloading.contains(paper.key) {
            parts.append("downloading…")
        } else if Store.shared.isDownloaded(paper) {
            parts.append("offline")
        } else {
            parts.append("on laptop")
        }
        if count > 0 { parts.append("\(count) annotation\(count == 1 ? "" : "s")") }
        if let minutes = paper.repMinutes { parts.append("\(minutes) min rep") }

        cell.detailTextLabel?.text = parts.joined(separator: " · ")
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)
        cell.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - Read and offload
    //
    // Swipe actions rather than always-visible controls: these are occasional
    // acts of bookkeeping, and putting two buttons on every row would crowd a
    // 7.9" screen for something used once per paper.

    override func tableView(_ tableView: UITableView,
                            editActionsForRowAt indexPath: IndexPath)
                            -> [UITableViewRowAction]? {
        let paper = self.paper(at: indexPath)
        let isRead = Store.shared.isRead(paper.key)

        let readAction = UITableViewRowAction(
            style: .normal, title: isRead ? "Unread" : "Read") { [weak self] _, path in
            guard let self = self else { return }
            Store.shared.setRead(paper.key, !isRead)
            SyncClient.shared.setRead(paper, !isRead)
            tableView.setEditing(false, animated: true)
            self.tableView.reloadSections(IndexSet(integer: path.section),
                                          with: .none)
        }
        readAction.backgroundColor = UIColor(red: 0.24, green: 0.5, blue: 0.36, alpha: 1)

        // Offloading only makes sense for something actually taking up space.
        guard Store.shared.isDownloaded(paper) else { return [readAction] }

        let offload = UITableViewRowAction(
            style: .destructive, title: "Offload") { [weak self] _, path in
            self?.confirmOffload(paper, at: path)
        }
        return [offload, readAction]
    }

    override func tableView(_ tableView: UITableView,
                            canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    /// Offloading deletes the only copy on the device, so it asks — and it says
    /// plainly when the paper has nothing to show for itself, since that is the
    /// case where you probably meant to keep reading it.
    private func confirmOffload(_ paper: Paper, at indexPath: IndexPath) {
        let annotations = Store.shared.annotations(for: paper.key).count
        let notes = Store.shared.guideNotes.filter { $0.paperKey == paper.key }.count
        let unsynced = SyncClient.shared.lastSync == nil

        var message = "Removes the PDF from this iPad. "
            + "\(annotations) annotations and \(notes) guide notes stay, "
            + "and sync to the laptop."
        if annotations == 0 && notes == 0 {
            message += "\n\nNothing has been captured from this paper yet."
        }
        if unsynced {
            message += "\n\nThis device has never synced — sync first."
        }

        let alert = UIAlertController(title: "Offload \(paper.title)?",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Offload", style: .destructive) { _ in
            Store.shared.offload(paper)
            SyncClient.shared.reportOffload(paper, annotations: annotations,
                                            guideNotes: notes)
            self.tableView.reloadRows(at: [indexPath], with: .automatic)
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let paper = self.paper(at: indexPath)

        if Store.shared.isDownloaded(paper) {
            open(paper)
            return
        }

        // Downloading is explicit, so you always know what you are carrying
        // before you lose signal.
        downloading.insert(paper.key)
        tableView.reloadRows(at: [indexPath], with: .none)
        SyncClient.shared.download(paper) { [weak self] ok, reason in
            guard let self = self else { return }
            self.downloading.remove(paper.key)
            self.tableView.reloadRows(at: [indexPath], with: .none)
            if ok {
                self.open(paper)
            } else {
                self.reportFailure(paper: paper, reason: reason)
            }
        }
    }

    /// Say why. A download that fails silently looks identical to one that
    /// hung, and leaves nothing to debug from -- which is exactly what the
    /// double-encoded URL bug looked like on the device.
    private func reportFailure(paper: Paper, reason: String?) {
        let alert = UIAlertController(
            title: "Couldn't download",
            message: (reason ?? "Unknown error") + "\n\n" + paper.filename,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func open(_ paper: Paper) {
        navigationController?.pushViewController(
            ReaderViewController(paper: paper), animated: true)
    }
}
