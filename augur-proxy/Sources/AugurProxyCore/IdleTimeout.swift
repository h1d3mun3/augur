import Foundation

// Idle-timeout support for the proxy's established-tunnel splice (issue #101).
//
// Once a connection is past the handshake, `spliceBoth` copies bytes both ways. Without a
// timeout, a guest can hold an established-but-IDLE tunnel open forever, pinning a
// `connectionCap` slot (a bounded DoS: up to `--max-connections` slots). TCP keepalive only
// detects a DEAD peer, not an alive-but-idle one, so it does not close this.
//
// The decision logic lives here in the testable core (not the executable target, where the
// raw syscalls live) so every branch is unit-tested rather than only review-checked — the
// same split as `AddressPolicy`/`Allowlist`. The executable maps `read()`/`write()` results
// and errno to these pure classifiers and owns the actual socket timeouts and teardown.
//
// Boundary of the guarantee: "idle" means ZERO bytes moving in EITHER direction. A guest that
// keeps trickling even one byte within each window is by definition an ACTIVE tunnel and is NOT
// reclaimed — this is the same property that (correctly) preserves a low-traffic SSE/long-poll
// stream, so it is accepted, not a hole. What #101 closes is the pure zero-progress pin (a guest
// that stops reading AND sending); the connection cap still bounds the trickle case to
// `--max-connections` slots.

/// Shared idle clock for ONE bidirectional tunnel. Both splice directions bump it on activity
/// and consult it on a read/write timeout, so a byte moving in EITHER direction keeps BOTH
/// directions alive — a low-traffic-but-live stream (SSE, long-poll) is preserved, while a
/// tunnel with zero progress either way for `idleNanos` is torn down.
///
/// MUST be a reference type: the two splice threads share ONE instance so activity is visible
/// across directions (a `struct` copy would silently give each direction its own clock and
/// break the cross-direction preservation — see `IdleTimeoutTests`). NSLock-guarded, matching
/// `InFlightGauge`/`DecisionLog`; the clock is INJECTED by the caller
/// (`DispatchTime.now().uptimeNanoseconds`) so this stays deterministic and unit-testable.
public final class IdleTracker {
    private let lock = NSLock()
    private var last: UInt64
    public let idleNanos: UInt64

    public init(idleNanos: UInt64, now: UInt64) {
        self.idleNanos = idleNanos
        self.last = now
    }

    /// Record activity (bytes moved in some direction).
    public func bump(_ now: UInt64) {
        lock.lock()
        last = now
        lock.unlock()
    }

    /// True once the whole tunnel has been idle (no activity in either direction) for at least
    /// `idleNanos`. `&-` (wrapping subtract): the caller's clock is monotonic so `now >= last`
    /// always holds, but wrapping keeps the delta correct even if that ever failed to hold.
    public func expired(_ now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (now &- last) >= idleNanos
    }
}

/// What a `read()` in the splice loop means. Pure so every branch is unit-tested.
public enum SpliceRead: Equatable {
    case data(Int)     // n > 0: forward these bytes, then bump the idle clock
    case eof           // n == 0: clean half-close
    case idleTimeout   // n < 0, receive timeout fired (idle on): consult the shared clock
    case error         // n < 0 genuine error, OR any n < 0 when idle is off (== today's n<=0 break)
}

/// Classify a `read()` result. `wouldBlock` = the read failed with EAGAIN/EWOULDBLOCK, i.e. a
/// `SO_RCVTIMEO` receive-timeout fired (the executable computes this from errno; the two consts
/// are equal on Linux and Darwin). It is only meaningful when `idleEnabled` — with idle off no
/// timeout is set, so any `n < 0` is a genuine error, exactly as before this feature.
public func classifyRead(n: Int, wouldBlock: Bool, idleEnabled: Bool) -> SpliceRead {
    if n > 0 { return .data(n) }
    if n == 0 { return .eof }
    if idleEnabled && wouldBlock { return .idleTimeout }
    return .error
}

/// What a `write()` in the splice loop means. Pure so every branch is unit-tested.
public enum SpliceWrite: Equatable {
    case wrote(Int)    // w > 0: advance the write offset, then bump the idle clock
    case idleTimeout   // w < 0, send timeout fired (idle on): consult the shared clock
    case error         // w == 0, a genuine write error, OR w < 0 when idle is off (== today's w<=0 break)
}

/// Classify a `write()` result. `wouldBlock` mirrors `classifyRead` but for `SO_SNDTIMEO` (a
/// send timeout — a peer that stopped draining, e.g. a guest that stopped reading). The caller
/// only sets `wouldBlock` true when `w < 0`, so `.idleTimeout` never masks a `w == 0`.
public func classifyWrite(w: Int, wouldBlock: Bool, idleEnabled: Bool) -> SpliceWrite {
    if w > 0 { return .wrote(w) }
    if idleEnabled && wouldBlock { return .idleTimeout }
    return .error
}

/// How often the splice loop should re-check the shared idle clock (the `SO_RCVTIMEO`/
/// `SO_SNDTIMEO` value in seconds), so detection lag is bounded by ~this even when the idle
/// window is large. `0` → idle timeout disabled (restore the pre-#101 infinite-idle behavior).
public func idlePollSecs(idleTimeoutSecs: Int) -> Int {
    idleTimeoutSecs <= 0 ? 0 : min(idleTimeoutSecs, 30)
}
