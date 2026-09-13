import PDFKit
import UIKit

/// The PDF's own table of contents, as a list you can tap.
///
/// Papers are short enough to scroll; the textbooks on the reading list are
/// not. Creswell and Masters are three-hundred-page documents and the plan
/// sends the reader to chapter 4 -- which, without this, means paging through
/// a scanned contents table and then dragging a scrollbar with no page numbers
/// on it. The outline PDFKit already parses is the answer, and it survives the
/// margin crop the staging pipeline applies.
///
/// Flattened, with indentation for depth, rather than an expanding tree: on a
/// 7.9" screen a tree needs two taps per chapter and the whole outline of a
/// textbook fits in a couple of screens anyway.
final class OutlineViewController: UITableViewController {

    /// One row of the flattened outline.
    private struct Row {
        let title: String
        let depth: Int
        let pageIndex: Int?
    }

    private let document: PDFDocument
    private var rows: [Row] = []
    private let currentPage: Int

    /// Called with the zero-based page index to jump to. The reader owns the
    /// PDFView; this only reports the choice.
    var onSelect: ((Int) -> Void)?

    init(document: PDFDocument, currentPage: Int) {
        self.document = document
        self.currentPage = currentPage
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Whether a document has anything to show here. Checked before
    /// presenting, so a paper with no outline gets a one-line message instead
    /// of an empty screen.
    static func hasOutline(_ document: PDFDocument) -> Bool {
        guard let root = document.outlineRoot else { return false }
        return root.numberOfChildren > 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contents"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        if let root = document.outlineRoot {
            flatten(root, depth: 0)
        }
        tableView.reloadData()
        scrollToCurrent()
    }

    private func flatten(_ node: PDFOutline, depth: Int) {
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var page: Int?
            if let dest = child.destination, let p = dest.page {
                page = document.index(for: p)
            }
            // An entry with no label and no target is a structural node in
            // some generators' outlines; it carries nothing worth a row.
            if !label.isEmpty || page != nil {
                rows.append(Row(title: label.isEmpty ? "(untitled)" : label,
                                depth: depth, pageIndex: page))
            }
            flatten(child, depth: depth + 1)
        }
    }

    /// Open on the section you are in, not on the front matter.
    private func scrollToCurrent() {
        var best: Int?
        for (i, row) in rows.enumerated() {
            guard let p = row.pageIndex, p <= currentPage else { continue }
            best = i
        }
        guard let index = best else { return }
        tableView.scrollToRow(at: IndexPath(row: index, section: 0),
                              at: .middle, animated: false)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "row")
        let row = rows[indexPath.row]

        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 0
        // Top-level entries are chapters; everything under them is smaller and
        // indented so the shape of the book is visible without a tree control.
        cell.textLabel?.font = row.depth == 0
            ? UIFont.systemFont(ofSize: 16, weight: .semibold)
            : UIFont.systemFont(ofSize: 14)
        cell.textLabel?.textColor = row.depth == 0
            ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.3, alpha: 1)
        cell.indentationLevel = min(row.depth, 4)
        cell.indentationWidth = 18

        if let p = row.pageIndex {
            cell.detailTextLabel?.text = "p. \(p + 1)"
            cell.selectionStyle = .default
        } else {
            cell.detailTextLabel?.text = nil
            cell.selectionStyle = .none
        }
        cell.detailTextLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 13,
                                                                     weight: .regular)
        cell.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)

        // Mark the section the reader is currently in.
        cell.backgroundColor = isCurrentSection(indexPath.row)
            ? UIColor(red: 0.98, green: 0.94, blue: 0.85, alpha: 1) : .white
        return cell
    }

    /// True for the last entry whose page is at or before the current one --
    /// the section being read -- and false for everything else.
    private func isCurrentSection(_ index: Int) -> Bool {
        guard let start = rows[index].pageIndex, start <= currentPage else { return false }
        var i = index + 1
        while i < rows.count {
            if let next = rows[i].pageIndex {
                return currentPage < next
            }
            i += 1
        }
        return true
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let page = rows[indexPath.row].pageIndex else { return }
        onSelect?(page)
        dismiss(animated: true)
    }
}
