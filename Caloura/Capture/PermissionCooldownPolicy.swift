import Foundation

/// Pure cooldown policy for permission alerts. Owns the thresholds that
/// decide whether to suppress a blocking alert or an auto-repair relaunch.
/// The timestamps themselves live in `PermissionStore`; this type stays a
/// pure function of (timestamp, now) so the timing logic can be reasoned
/// about (and tested) without UserDefaults or the coordinator's async
/// state machine.
struct PermissionCooldownPolicy {
    let alertCooldownSeconds: TimeInterval
    let autoRepairRelaunchCooldownSeconds: TimeInterval

    init(
        alertCooldownSeconds: TimeInterval = 45,
        autoRepairRelaunchCooldownSeconds: TimeInterval = 60
    ) {
        self.alertCooldownSeconds = alertCooldownSeconds
        self.autoRepairRelaunchCooldownSeconds = autoRepairRelaunchCooldownSeconds
    }

    func isAlertCooldownActive(lastBlockingAlertAt: Date?, at timestamp: Date) -> Bool {
        lastBlockingAlertAt.map {
            timestamp.timeIntervalSince($0) < alertCooldownSeconds
        } ?? false
    }

    func canAttemptAutoRepairRelaunch(lastAttemptAt: Date?, at timestamp: Date) -> Bool {
        guard let lastAttemptAt else {
            return true
        }
        return timestamp.timeIntervalSince(lastAttemptAt) > autoRepairRelaunchCooldownSeconds
    }
}
