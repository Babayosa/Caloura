import Foundation

/// Pure cooldown policy for permission alerts. Owns the timestamps and the
/// thresholds that decide whether to suppress a blocking alert or an
/// auto-repair relaunch. Extracted from `PermissionCoordinator` so the
/// timing logic can be reasoned about (and tested) without the coordinator's
/// async state machine, NSAlert presenter, and UI-model updates.
struct PermissionCooldownPolicy {
    var lastBlockingAlertAt: Date?
    let alertCooldownSeconds: TimeInterval
    let autoRepairRelaunchCooldownSeconds: TimeInterval
    let now: () -> Date
    let defaults: UserDefaults
    let lastAutoRepairRelaunchKey: String

    init(
        defaults: UserDefaults,
        lastAutoRepairRelaunchKey: String,
        alertCooldownSeconds: TimeInterval = 45,
        autoRepairRelaunchCooldownSeconds: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.lastAutoRepairRelaunchKey = lastAutoRepairRelaunchKey
        self.alertCooldownSeconds = alertCooldownSeconds
        self.autoRepairRelaunchCooldownSeconds = autoRepairRelaunchCooldownSeconds
        self.now = now
    }

    func isCooldownActive(at timestamp: Date) -> Bool {
        lastBlockingAlertAt.map {
            timestamp.timeIntervalSince($0) < alertCooldownSeconds
        } ?? false
    }

    mutating func markBlockingAlertShown(at timestamp: Date) {
        lastBlockingAlertAt = timestamp
    }

    func canAttemptAutoRepairRelaunch() -> Bool {
        guard let lastAt = defaults.object(forKey: lastAutoRepairRelaunchKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(lastAt) > autoRepairRelaunchCooldownSeconds
    }

    func markAutoRepairRelaunchAttempted() {
        defaults.set(now(), forKey: lastAutoRepairRelaunchKey)
    }
}
