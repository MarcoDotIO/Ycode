import Testing

/// Suites that flip process-wide kernel switches (`KernelLock.wakeAfterUnlock`,
/// `SyncHandoff.pinHook`). They are nested here so that they run one after
/// another: Swift Testing runs separate suites in parallel in one process.
@Suite(.serialized) enum KernelSwitchSuites {}
