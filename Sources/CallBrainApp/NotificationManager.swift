import Foundation
import UserNotifications

/// Local notifications for open action items (Phase 6). Action items rarely carry explicit due dates, so
/// the honest design is a **daily nudge** with the current open-task count — pre-scheduled so it fires
/// even when the app is quit, and rescheduled on launch / when tasks change so the count stays fresh.
/// No-ops safely when there's no bundle identifier (an unsigned dev run) — delivery needs the packaged app.
@MainActor
enum NotificationManager {
    static let enabledKey = "callbrain.taskRemindersEnabled"
    static let reminderID = "callbrain.dailyTaskReminder"
    static let reminderHour = 9

    static var available: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Toggle from Settings: request authorization when turning on; schedule/cancel accordingly.
    static func setEnabled(_ on: Bool, openTaskCount: Int) async {
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard available else { return }
        if on {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            // Re-check the desired state after the await (the user may have toggled off, or auth was
            // denied) before scheduling — avoids a UI/defaults/pending-request desync (P6 gate LOW).
            guard isEnabled else { cancel(); return }
            if granted { scheduleDailyReminder(openTaskCount: openTaskCount) }
            else { UserDefaults.standard.set(false, forKey: enabledKey) }
        } else {
            cancel()
        }
    }

    /// Re-arm the reminder with the latest count (call on launch + whenever tasks change).
    static func refresh(openTaskCount: Int) {
        guard available, isEnabled else { return }
        scheduleDailyReminder(openTaskCount: openTaskCount)
    }

    private static func scheduleDailyReminder(openTaskCount: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard openTaskCount > 0 else { return }   // nothing to nudge about

        let content = UNMutableNotificationContent()
        content.title = "Open action items"
        content.body = "You have \(openTaskCount) open task\(openTaskCount == 1 ? "" : "s") across your calls — review them in Recap."
        content.sound = .default

        var when = DateComponents(); when.hour = reminderHour
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        center.add(UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger))
    }

    private static func cancel() {
        guard available else { return }
        // Remove ALL pending — the daily reminder AND any one-off prep-ready notifications
        // (audit HIGH: turning reminders off left callbrain.prep.* firing). Recap only
        // ever schedules these two kinds, so clearing all is safe.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Cancel a specific call's prep-ready nudge (e.g. the event was deleted / rescheduled).
    static func cancelPrepReady(eventID: String) {
        guard available else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["callbrain.prep.\(eventID)"])
    }

    // MARK: - prep-ready (Calendar v4)

    static let prepLeadMinutes = 30

    /// One-off "your 2pm — prep's ready" ~30 min before a call whose brief already exists.
    /// Idempotent per event id; silently no-ops if the fire time is already past or the
    /// notifications toggle is off.
    static func schedulePrepReady(eventID: String, title: String, start: Date) {
        guard available, isEnabled else { return }
        let id = "callbrain.prep.\(eventID)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let fireAt = start.addingTimeInterval(TimeInterval(-prepLeadMinutes * 60))
        let delay = fireAt.timeIntervalSinceNow
        guard delay > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Prep ready — \(title)"
        content.body = "Your brief is ready. Open Recap to review before the call."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
