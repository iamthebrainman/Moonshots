//! root.zig - test root for the SUNZI proof.
//!
//!   zig test src/root.zig
//!
test {
    _ = @import("rng.zig");
    _ = @import("big.zig");
    _ = @import("primes.zig");
    _ = @import("sunzi.zig");
    _ = @import("named.zig");
    _ = @import("knowledge.zig");
}
