import XCTest
@testable import AugurProxyCore

/// Idle-timeout logic for the proxy's established-tunnel splice (#101). The syscall glue lives
/// in the executable target; the bug-prone decisions live in the core and are asserted here.
final class IdleTimeoutTests: XCTestCase {

    private let sec: UInt64 = 1_000_000_000

    // MARK: IdleTracker

    // Boundary is `>=`, not `>`: exactly `idleNanos` of silence expires.
    func testExpiryBoundaryIsInclusive() {
        let t = IdleTracker(idleNanos: 10 * sec, now: 1_000)
        XCTAssertFalse(t.expired(1_000))                 // no time passed
        XCTAssertFalse(t.expired(1_000 + 10 * sec - 1))  // one ns short
        XCTAssertTrue(t.expired(1_000 + 10 * sec))       // exactly at the threshold
        XCTAssertTrue(t.expired(1_000 + 100 * sec))      // well past
    }

    // A bump resets the window: activity that would have expired keeps the tunnel alive, and the
    // clock is measured from the LATEST bump.
    func testBumpResetsTheWindow() {
        let t = IdleTracker(idleNanos: 5 * sec, now: 0)
        XCTAssertTrue(t.expired(5 * sec))                // would expire...
        t.bump(6 * sec)                                  // ...but activity arrived
        XCTAssertFalse(t.expired(6 * sec))               // window restarts from the bump
        XCTAssertFalse(t.expired(6 * sec + 5 * sec - 1))
        XCTAssertTrue(t.expired(6 * sec + 5 * sec))      // expires 5s after the latest activity
    }

    // `&-` (wrapping subtract): a backwards `now` (never happens with a monotonic clock) must
    // not TRAP the way plain `UInt64` `-` would; and the true small delta must still compute
    // correctly right at the UInt64 ceiling.
    func testMonotonicSubtractIsWrapSafe() {
        let backwards = IdleTracker(idleNanos: 10 * sec, now: 100)
        _ = backwards.expired(50)                      // 50 &- 100 wraps huge — the point is: no crash
        let nearCeiling = IdleTracker(idleNanos: 10 * sec, now: UInt64.max - 100)
        XCTAssertFalse(nearCeiling.expired(UInt64.max - 50))  // real delta 50ns, well under threshold
        XCTAssertFalse(nearCeiling.expired(UInt64.max - 100)) // same instant
    }

    // Reference semantics are load-bearing: both splice directions share ONE tracker so activity
    // in either direction is visible to both. A struct copy would silently break SSE preservation.
    func testSharedInstanceIsVisibleAcrossAliases() {
        let shared = IdleTracker(idleNanos: 3 * sec, now: 0)
        let dirA = shared, dirB = shared            // the two splice directions
        XCTAssertTrue(dirB.expired(3 * sec))        // idle so far
        dirA.bump(4 * sec)                          // direction A saw a byte
        XCTAssertFalse(dirB.expired(4 * sec))       // direction B sees A's activity — tunnel stays up
    }

    // Concurrent bump/expired must not crash or trap (NSLock present).
    func testConcurrentAccessIsSafe() {
        let t = IdleTracker(idleNanos: sec, now: 0)
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            if i % 2 == 0 { t.bump(UInt64(i)) } else { _ = t.expired(UInt64(i)) }
        }
    }

    // MARK: classifyRead

    func testClassifyReadData()  { XCTAssertEqual(classifyRead(n: 42, wouldBlock: false, idleEnabled: true), .data(42)) }
    func testClassifyReadEOF()   { XCTAssertEqual(classifyRead(n: 0,  wouldBlock: false, idleEnabled: true), .eof) }

    func testClassifyReadTimeoutOnlyWhenIdleEnabled() {
        // n<0 + would-block: a receive timeout only when idle is on; otherwise a genuine error.
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: true,  idleEnabled: true),  .idleTimeout)
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: true,  idleEnabled: false), .error)
    }

    func testClassifyReadGenuineErrorIsNeverTimeout() {
        // n<0 without would-block (e.g. ECONNRESET) is always a teardown, idle or not.
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: false, idleEnabled: true),  .error)
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: false, idleEnabled: false), .error)
    }

    // Legacy parity: with idle OFF, every n<=0 maps to a teardown, exactly like the old `n<=0 break`.
    func testClassifyReadLegacyParityWhenIdleOff() {
        XCTAssertEqual(classifyRead(n: 0,  wouldBlock: false, idleEnabled: false), .eof)
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: true,  idleEnabled: false), .error)
        XCTAssertEqual(classifyRead(n: -1, wouldBlock: false, idleEnabled: false), .error)
    }

    // MARK: classifyWrite

    func testClassifyWriteWrote() { XCTAssertEqual(classifyWrite(w: 100, wouldBlock: false, idleEnabled: true), .wrote(100)) }

    func testClassifyWriteTimeoutOnlyWhenIdleEnabled() {
        XCTAssertEqual(classifyWrite(w: -1, wouldBlock: true,  idleEnabled: true),  .idleTimeout)
        XCTAssertEqual(classifyWrite(w: -1, wouldBlock: true,  idleEnabled: false), .error)
    }

    func testClassifyWriteZeroAndErrorAreTeardown() {
        XCTAssertEqual(classifyWrite(w: 0,  wouldBlock: false, idleEnabled: true),  .error)  // 0 bytes written
        XCTAssertEqual(classifyWrite(w: -1, wouldBlock: false, idleEnabled: true),  .error)  // genuine error
        XCTAssertEqual(classifyWrite(w: -1, wouldBlock: true,  idleEnabled: false), .error)  // idle off → legacy break
    }

    // MARK: idlePollSecs

    func testPollSecsDisabledAtZeroOrNegative() {
        XCTAssertEqual(idlePollSecs(idleTimeoutSecs: 0), 0)
        XCTAssertEqual(idlePollSecs(idleTimeoutSecs: -5), 0)
    }

    func testPollSecsCappedAtThirty() {
        XCTAssertEqual(idlePollSecs(idleTimeoutSecs: 2), 2)      // small window: poll == window
        XCTAssertEqual(idlePollSecs(idleTimeoutSecs: 30), 30)
        XCTAssertEqual(idlePollSecs(idleTimeoutSecs: 900), 30)   // large window: re-check at least every 30s
    }
}
