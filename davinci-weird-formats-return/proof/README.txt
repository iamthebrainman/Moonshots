SUNZI proof

COMMAND (from this directory)

    zig test src/root.zig

That is the whole build. It compiles the library and its tests together and runs all 54 tests in a few
seconds in Debug. Exit status 0 means every test passed. There is no build.zig on purpose: its API differs
between the Zig releases below; `zig test` does not.

ZIG VERSIONS
Verified on 0.14.1, 0.15.2, 0.16.0 and 0.17.0 (x86_64-linux) in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall, and on wasm32-wasi under Node 22's WASI with --stack 8388608. See RUN_LOG.txt.
Toolchains came from the PyPI `ziglang` wheels (ziglang.org was not reachable from the sandbox).

NO DEPENDENCIES
Zig standard library only; no allocator, no I/O, no Python. Randomness, hashes and the bignum are defined
in this directory because std.Random, std hashes and std.math.big differ between releases and the
determinism claims must not depend on them.

FILES
  src/root.zig        test root
  src/sunzi.zig       THE FORMAT: put/get/has/del/view/diff/glue/seal/encode/decode
  src/big.zig         fixed-capacity bignum (Knuth D division, binary gcd)
  src/primes.zig      exact primality for u32, modular inverse, sieve
  src/named.zig       optional dictionary-free addressing by name, and its failure modes
  src/knowledge.zig   relation facts with provenance in the key, student/teacher in one gcd, the demo
  src/rng.zig         SplitMix64
  audit/exhibit_audit.zig   optional: `zig test audit/exhibit_audit.zig` reproduces the reference
                      measurements cited in GAPS.txt part 4
  RUN_LOG.txt         the build matrix that was run

READING THE OUTPUT
Passing tests print one line each. Lines tagged [golden], [measure], [seal], [amplification], [enumerate],
[named], [glue] and [demo] are measurements and the narrated student/teacher run. Add -O ReleaseFast for
timing figures that mean something. std.time timers do not exist in Zig 0.16 / 0.17, so there the [measure]
lines print counts and no times; the tests do not depend on them.

CAPACITY
Stores are comptime-sized (Store(256) = 8,192 bits, about 270 facts at 29-bit keys). An operation that does
not fit returns error.Overflow and leaves the store unchanged.
