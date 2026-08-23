import Foundation

/// Durations: 90 · 90m · 2h · 1h30m · 45min · 30s · 2H · 2h15.
/// Bare number = minutes; a trailing bare number after a unit = minutes.
public enum Durations {
    public static func parse(_ text: String) -> Int? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        if t.allSatisfy(\.isNumber) {
            guard let n = Int(t) else { return nil }
            return n > 0 ? n * 60 : nil
        }
        var total = 0
        var matchedUnit = false
        var i = t.startIndex
        while i < t.endIndex {
            var j = i
            while j < t.endIndex, t[j].isNumber { j = t.index(after: j) }
            guard j > i, let n = Int(t[i..<j]) else { return nil }
            var k = j
            while k < t.endIndex, t[k].isLetter { k = t.index(after: k) }
            let unit = String(t[j..<k])
            if unit.isEmpty {
                // "2h15" — a trailing bare number means minutes, and only at the end.
                guard k == t.endIndex else { return nil }
                total += n * 60
            } else {
                switch unit {
                case "h", "hour", "hours": total += n * 3600
                case "m", "min", "minute", "minutes": total += n * 60
                case "s", "sec", "second", "seconds": total += n
                default: return nil
                }
                matchedUnit = true
            }
            i = k
        }
        return (matchedUnit && total > 0) ? total : nil
    }

    /// HH:MM → epoch. If the time is already behind us, tomorrow is meant.
    /// Computed from `now` (fake-aware); the wall-clock date it lands on uses
    /// the real local timezone, which is the absolute-formatting half of the
    /// SIMMER_FAKE_NOW contract.
    public static func parseUntil(_ text: String, now: Int) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let nowDate = Date(timeIntervalSince1970: TimeInterval(now))
        var components = calendar.dateComponents([.year, .month, .day], from: nowDate)
        components.hour = h
        components.minute = m
        components.second = 0
        guard let target = calendar.date(from: components) else { return nil }
        var epoch = Int(target.timeIntervalSince1970)
        if epoch <= now { epoch += 86_400 }
        return epoch
    }

    /// "1 h 20 min" · "45 min" · "under 1 min"
    public static func human(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "under 1 min"
    }

    /// "1h20" · "42m" — for the menu bar.
    public static func short(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(format: "%dh%02d", h, m) }
        return "\(m)m"
    }
}

/// Absolute formatting. Deliberately NOT behind SIMMER_FAKE_NOW: the fake
/// moves relative arithmetic, not what a given epoch reads as on this Mac.
public enum Formats {
    public static func hhmm(_ epoch: Int) -> String {
        formatted(epoch, "HH:mm")
    }

    public static func logStamp(_ epoch: Int) -> String {
        formatted(epoch, "yyyy-MM-dd HH:mm:ss")
    }

    private static func formatted(_ epoch: Int, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
