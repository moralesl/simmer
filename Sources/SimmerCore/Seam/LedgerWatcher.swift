import Foundation

/// Tells a long-running process when the ledger changed underneath it.
///
/// The menu bar and the CLI are two processes over one directory of files, so
/// without this the app can only poll: `simmer 2h` in a terminal writes a claim
/// and the menu bar shows the old truth until its next tick. Polling faster is
/// the wrong fix — each refresh reads the power state, which costs a
/// subprocess. Watching costs nothing until something actually happens.
///
/// Deliberately watches the **claims directory** and the **cap**, not the whole
/// state directory: the log, the event stream, the notification spool and the
/// app's own heartbeat all live there and all change on their own schedule,
/// which would turn a change signal into a metronome. A cap that appears for
/// the first time is therefore seen by the caller's periodic backstop rather
/// than instantly — a human sets a cap perhaps twice a day, and every claim
/// takes the fast path.
public final class LedgerWatcher: @unchecked Sendable {
    private let ledger: Ledger
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "simmer.ledger-watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var running = false

    /// `onChange` is called on an internal serial queue, coalesced: a burst of
    /// writes — a claim file, then the cap, then a rename — is one call.
    public init(ledger: Ledger, debounce: TimeInterval = 0.15,
                onChange: @escaping () -> Void) {
        self.ledger = ledger
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            arm()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            pending?.cancel()
            pending = nil
            disarm()
        }
    }

    // MARK: - internals, all on `queue`

    private func arm() {
        // The claims directory is the authority on what is claimed; the cap
        // file only exists while a human has set one.
        watch(ledger.claimsDir)
        if FileManager.default.fileExists(atPath: ledger.capFile.path) {
            watch(ledger.capFile)
        }
    }

    private func disarm() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }

    private func watch(_ url: URL) {
        // O_EVTONLY: opened to be told about, not to read — it does not keep
        // the file from being deleted or the volume from unmounting.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            // The watched thing was replaced or removed: a temp-file rename
            // over the cap, or the whole state directory being cleaned out.
            // The descriptor now points at something that no longer exists, so
            // re-establish before reporting — otherwise the first change is
            // also the last one ever seen.
            if !data.intersection([.delete, .rename, .revoke]).isEmpty {
                self.rearm()
            }
            self.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func rearm() {
        guard running else { return }
        disarm()
        arm()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
