import Foundation

/*
 One entry point per suite, grouped by the file it lives in.

 Hand-maintained, and therefore checked: `runSuiteWiringTests` fails if any
 `func run…Tests` in this directory is missing from the list below. A suite that is
 defined and never called compiles, looks complete, and reports success — the same
 shape as every real bug this project has had.
*/

// The device: protocol, wire format, and why the pad is not there.
runProtocolTests()
runWriteShapeTests()
runShowTests()
runDiagnosticsTests()
runTransportTests()
runCalibrationCaptureTests()

// Sessions: what holds a key, what releases it, and what it is called.
runRegistryTests()
runPruneTests()
runBoardRowTests()
runDoneSurvivalTests()
runDiscoveryTests()
runRegistryStoreTests()
runDoneHoldsTests()
runSessionTitleTests()
runTerminalTitleTests()
runSessionOriginTests()
runTranscriptLocateTests()
runProcessAncestryTests()
runRowDetailTests()

// Hooks: the only way a session reaches the board.
runHookTests()
runHookInstallTests()
runKeybindingInstallTests()
runHookOmissionTests()
runEventGatingTests()
runToolEventTests()

// Controls: keys, dial, stick, and the focus overlay.
runDispatcherTests()
runViewingTests()
runFocusPulseTests()
runScrollTests()
runEncoderClickTests()
runHoldTests()
runJoystickTests()
runFocusITerm2Tests()

// Configuration and where it lives.
runPreferencesTests()
runShortcutTests()
runAppPathsTests()
runKeyOrderTests()
runHoldTests2()
runVoiceRingTests()
runVoiceSignalTests()
runHarnessTests()
runAgentDetectionTests()
runHarnessSeenTests()
runTurnStateTests()
runToolProgressTests()
runPermissionCoverageTests()
runPermissionStatusTests()
runSecureInputTests()
runSetupProgressTests()
runClaudeVoiceTests()

// The settings window itself.
runSelectionColorTests()
runSettingsPersistenceTests()
runITerm2SettingsUITests()
runSuiteWiringTests()

// Lighting behaviour.
runAmbientTests()
runLapTests()
runCountdownTests()

// Everything carried over from the Node version, unchanged on purpose.
runPortFidelityTests()
runAuditFollowUpTests()

// Async, and genuinely concurrent — the bug it guards against is invisible to a
// single-threaded test.
//
// `Task.detached`, not `Task`: top-level code is MainActor-isolated, so a plain Task
// inherits that isolation and can never run while the semaphore below blocks main.
// The suite then reported success by simply skipping these tests.
let lockDone = DispatchSemaphore(value: 0)
Task.detached { await runLockTests(); lockDone.signal() }
if lockDone.wait(timeout: .now() + 90) == .timedOut {
    FileHandle.standardError.write(Data("lock tests timed out\n".utf8))
    exit(1)
}
exit(Harness.summarise())
