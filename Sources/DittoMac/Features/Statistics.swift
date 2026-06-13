import Foundation

/// Copy/paste counters persisted in UserDefaults, mirroring the Windows
/// `TripCopies`/`TotalCopies`/`TripPastes`/`TotalPastes` options. "Trip" =
/// since last reset, "Total" = all-time.
final class Statistics {
    static let shared = Statistics()

    private enum Key {
        static let tripCopies = "Ditto.Stats.TripCopies"
        static let tripPastes = "Ditto.Stats.TripPastes"
        static let tripDate = "Ditto.Stats.TripDate"
        static let totalCopies = "Ditto.Stats.TotalCopies"
        static let totalPastes = "Ditto.Stats.TotalPastes"
        static let totalDate = "Ditto.Stats.TotalDate"
    }

    private init() {
        ensureTotalStartDate()
    }

    var tripCopies: Int { UserDefaults.standard.integer(forKey: Key.tripCopies) }
    var tripPastes: Int { UserDefaults.standard.integer(forKey: Key.tripPastes) }
    var totalCopies: Int { UserDefaults.standard.integer(forKey: Key.totalCopies) }
    var totalPastes: Int { UserDefaults.standard.integer(forKey: Key.totalPastes) }

    var tripStartDate: Date {
        if let interval = UserDefaults.standard.object(forKey: Key.tripDate) as? Double {
            return Date(timeIntervalSince1970: interval)
        }
        return Date()
    }

    var totalStartDate: Date {
        if let interval = UserDefaults.standard.object(forKey: Key.totalDate) as? Double {
            return Date(timeIntervalSince1970: interval)
        }
        return Date()
    }

    func recordCopy() {
        increment(Key.tripCopies)
        increment(Key.totalCopies)
    }

    func recordPaste() {
        increment(Key.tripPastes)
        increment(Key.totalPastes)
    }

    func resetTrip() {
        UserDefaults.standard.set(0, forKey: Key.tripCopies)
        UserDefaults.standard.set(0, forKey: Key.tripPastes)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.tripDate)
    }

    private func increment(_ key: String) {
        let value = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(value + 1, forKey: key)
    }

    private func ensureTotalStartDate() {
        if UserDefaults.standard.object(forKey: Key.totalDate) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.totalDate)
        }
    }
}
