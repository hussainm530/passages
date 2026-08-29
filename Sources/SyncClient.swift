import Foundation

/// Talks to the reader server on the ThinkPad over Tailscale.
///
/// Two properties matter more than anything else here, because they are the
/// two complaints that motivated the whole app:
///
/// 1. **Never blocks the UI.** Sync runs on a background `URLSession` and the
///    reader stays fully usable throughout. GoodReader's Connect-to-Computer
///    holds the app hostage in a modal server mode; nothing here does.
/// 2. **Never requires leaving the paper.** Annotations are pushed one at a
///    time as they are made. There is no "sync" step to go and find.
final class SyncClient {
    static let shared = SyncClient()

    /// The IdeaPad's Tailscale address. Stable, and only reachable on the
    /// tailnet, which is also the only authentication this has.
    ///
    /// This was the ThinkPad (`100.117.163.83`) until 28 Aug 2026. The reader
    /// server moved to the always-on IdeaPad because a desk laptop that sleeps
    /// is not a reading channel -- the whole point of the sub node. The app was
    /// the last piece still pointing at the old host. `ipad_sub.py` carries
    /// deliveries and recordings on to the ThinkPad, where Zotero, the vault
    /// and Moonshine live.
    var baseURL = URL(string: "http://100.77.134.90:8761")!

    private let session: URLSession
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private(set) var lastSync: Date? {
        get { return UserDefaults.standard.object(forKey: "lastSync") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSync") }
    }

    private init() {
        let config = URLSessionConfiguration.default
        // Short timeouts: offline is the expected case, not an error state.
        // Failing fast keeps the "syncing" indicator honest instead of
        // leaving it spinning for a minute on a train.
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Library

    func fetchLibrary(completion: @escaping ([Paper]?) -> Void) {
        let task = session.dataTask(with: baseURL.appendingPathComponent("api/library")) { data, _, _ in
            guard let data = data,
                  let papers = try? self.decoder.decode([Paper].self, from: data) else {
                completion(nil)
                return
            }
            DispatchQueue.main.async {
                Store.shared.setPapers(papers)
                completion(papers)
            }
        }
        task.resume()
    }

    /// Pull a PDF down for offline reading.
    ///
    /// Explicit rather than automatic: the reading lane is only ~8 MB total, so
    /// downloading everything would also be defensible, but making it a
    /// deliberate act means you always know what you have with you before you
    /// lose signal.
    func download(_ paper: Paper, completion: @escaping (Bool, String?) -> Void) {
        // Encode exactly once.
        //
        // The first version pre-encoded the filename with
        // addingPercentEncoding and then passed it to appendingPathComponent,
        // which encodes again -- so "%20" became "%2520" and every request
        // 404'd. Setting URLComponents.path takes the *raw* string and encodes
        // it on the way out, which is the one place the encoding happens.
        // These filenames all carry spaces and a bracketed Zotero key, so
        // there is no forgiving case to hide the bug.
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            completion(false, "Bad server URL")
            return
        }
        components.path = "/pdf/" + paper.filename
        guard let url = components.url else {
            completion(false, "Could not build URL for \(paper.filename)")
            return
        }

        let task = session.downloadTask(with: url) { temp, response, error in
            // Report *why* it failed. The silent-false version showed
            // "downloading..." and then simply stopped, which is
            // indistinguishable from a hang and says nothing useful.
            if let error = error {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let temp = temp, status == 200 else {
                DispatchQueue.main.async {
                    completion(false, "Server returned \(status)")
                }
                return
            }
            let dest = Store.shared.localURL(for: paper)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
                DispatchQueue.main.async { completion(true, nil) }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Could not save: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    // MARK: - Push

    /// Push one annotation immediately. Silent on failure by design.
    ///
    /// The local copy in `Store` is the record of truth; this is an
    /// opportunistic early delivery. Anything that does not land is picked up
    /// by `flush()` later, so a failed push is not worth interrupting reading
    /// for.
    func push(_ annotation: Annotation) {
        guard var request = jsonRequest(path: "api/annotations") else { return }
        request.httpBody = try? encoder.encode([annotation])
        session.dataTask(with: request).resume()
    }

    /// Send everything the laptop has not acknowledged, including voice notes.
    func flush(completion: ((Bool) -> Void)? = nil) {
        let pending = Store.shared.unsynced(since: lastSync)
        guard var request = jsonRequest(path: "api/sync") else {
            completion?(false)
            return
        }
        // Guide notes go every time rather than being diffed. There is at most
        // one per chunk and a handful per paper, so the bandwidth is nothing,
        // and the server upsert is keyed on id -- whereas a missed note is a
        // response to the method that exists nowhere else.
        let payload = SyncPayload(annotations: pending.annotations,
                                  reps: pending.reps,
                                  guideNotes: Store.shared.guideNotes)
        request.httpBody = try? encoder.encode(payload)

        session.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok {
                self.lastSync = Date()
                self.reconcileVoiceNotes()
            }
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }

    /// Voice notes go up as raw audio; transcription happens on the laptop with
    /// Moonshine, which cannot run on this hardware. The recording is the
    /// annotation until then -- deliberately, so speaking a thought is never
    /// blocked on a transcription that might not be available for hours.
    ///
    /// This asks the server what it already has and sends everything else. It
    /// used to walk the unsynced annotations instead, which lost thirteen
    /// recordings between 18 and 27 Aug 2026 in two separate ways:
    ///
    /// 1. **Guide notes were never considered.** `GuideNote` carries a
    ///    `voiceNote` exactly like `Annotation` does, and in practice that is
    ///    where the voice notes actually were -- every one of them. Speaking a
    ///    response to a guide question is the single most natural place to use
    ///    the microphone, and it was the one path that could not upload.
    /// 2. **A failed upload was never retried.** The old call took the
    ///    `unsynced(since: lastSync)` window, and `lastSync` had already moved
    ///    by the time it ran. One dropped connection -- the laptop asleep, the
    ///    8-second timeout -- and that recording was outside every future
    ///    window forever.
    ///
    /// Reconciling against the server has no window and no notion of what a
    /// recording is attached to, so neither failure can recur, and a backlog
    /// that built up while the laptop was away drains on the next sync.
    private func reconcileVoiceNotes() {
        let fm = FileManager.default
        let dir = Store.shared.voiceDir
        guard let local = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let mine = local.filter { $0.lowercased().hasSuffix(".m4a") }
        guard !mine.isEmpty else { return }

        let task = session.dataTask(with: baseURL.appendingPathComponent("api/voice")) { data, _, _ in
            // No listing means no upload. Sending blind would re-push the whole
            // directory on every sync once it holds a few dozen recordings.
            guard let data = data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let have = body["have"] as? [String] else { return }

            let held = Set(have)
            for name in mine where !held.contains(name) {
                self.uploadVoiceNote(name)
            }
        }
        task.resume()
    }

    /// Send one recording. Deliberately not deleted afterwards: the device is
    /// the offline-first record of truth, and the next reconcile will see the
    /// server has it and skip it.
    private func uploadVoiceNote(_ name: String) {
        let url = Store.shared.voiceDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/voice/\(name)"))
        request.httpMethod = "POST"
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: request, from: data).resume()
    }

    /// Tell the laptop this paper is (or is no longer) marked for a deep read.
    ///
    /// Fire and forget, like every other write here. The checkbox has already
    /// changed the guide on screen by the time this is called, and it must
    /// keep working with the laptop asleep -- so a failure here is a stale
    /// flag on the other machine, not a broken drawer. The next `/ipad-sync`
    /// is where the two get reconciled.
    func setDeepRead(_ paper: Paper, _ deep: Bool) {
        guard let planPaper = paper.planPaper, !planPaper.isEmpty,
              var request = jsonRequest(path: "api/deep") else { return }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["paper": planPaper, "deep": deep])
        session.dataTask(with: request).resume()
    }

    /// Report a read/unread mark. Fire and forget, like every other write.
    func setRead(_ paper: Paper, _ read: Bool) {
        guard var request = jsonRequest(path: "api/read") else { return }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["paper_key": paper.key, "title": paper.title,
                             "read": read])
        session.dataTask(with: request).resume()
    }

    /// Tell the laptop a paper left the device, with what it has to show for
    /// itself, so the vault side can ask about an offload that captured
    /// nothing rather than assuming the read happened.
    func reportOffload(_ paper: Paper, annotations: Int, guideNotes: Int) {
        guard var request = jsonRequest(path: "api/offload") else { return }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["paper_key": paper.key, "title": paper.title,
                             "annotation_count": annotations,
                             "guide_note_count": guideNotes])
        session.dataTask(with: request).resume()
    }

    private func jsonRequest(path: String) -> URLRequest? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

private struct SyncPayload: Encodable {
    let annotations: [Annotation]
    let reps: [Rep]
    let guideNotes: [GuideNote]

    enum CodingKeys: String, CodingKey {
        case annotations, reps
        case guideNotes = "guide_notes"
    }
}
