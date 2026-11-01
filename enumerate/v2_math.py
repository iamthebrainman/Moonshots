#!/usr/bin/env python3
"""
PROVISIONAL V2 - math library (standard library only, no LLM, no network).
Built 2026-11-01 as the V2 extension of enumerate_v1_provisional.py.
Not John's final spec. Each block below is a port of math already present
in this workspace, so the V2 slot fillers use the framework's own math:

  SplitMix64 / FNV-1a   the deterministic RNG and hash used by SUNZI (Moonshots/davinci-weird-formats-return)
  SUNZI (M, K)          the knowledge base that is one pair of integers (CRT): put/get/has/del/glue
  KEYSPACE              primes above 2^25 in each odd residue class mod 8 (speaker rides in the key)
  THE WORD hashes       the 10 geometric hash methods of GeometricHashVisualizer.html, 16-bit address space
  MAP vectors           bipolar hypervectors for the bundle / cosine side (RDLA ctx bundles)
"""

import math
from math import gcd

MASK64 = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed):
        self.s = seed & MASK64

    def next(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & MASK64
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n


def fnv1a64(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & MASK64
    return h


# ---------------------------------------------------------------- primes
def is_prime(n):
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for a in (2, 3, 5, 7, 11):  # exact for n < 2,152,302,898,747
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def build_keyspace(per_class=64):
    by = {1: [], 3: [], 5: [], 7: []}
    n = (1 << 25) + 1
    while any(len(v) < per_class for v in by.values()):
        if is_prime(n) and len(by[n & 7]) < per_class:
            by[n & 7].append(n)
        n += 2
    return by


KEYSPACE = build_keyspace()


# ---------------------------------------------------------------- SUNZI
class Conflict(Exception):
    pass


class Sunzi:
    """The whole base is two integers: M = product of keys, K = CRT residue."""

    __slots__ = ("M", "K")

    def __init__(self, M=1, K=0):
        self.M, self.K = M, K

    def has(self, p):
        return self.M % p == 0

    def get(self, p):
        return self.K % p if self.M % p == 0 else None

    def put(self, p, v):
        assert 0 <= v < p
        if self.M % p == 0:  # W2 overwrite
            q = self.M // p
            t = ((v - self.K) * pow(q, -1, p)) % p
            k = self.K + q * t
            self.K = k - self.M if k >= self.M else k
        else:  # W1 new key
            t = ((v - self.K) * pow(self.M, -1, p)) % p
            self.K += self.M * t
            self.M *= p

    def delete(self, p):  # W3
        if self.M % p == 0:
            self.M //= p
            self.K %= self.M

    def glue(self, other):  # W4: one CRT step, Conflict if they disagree
        g = gcd(self.M, other.M)
        m2 = other.M // g
        d = other.K - self.K
        if d % g:
            raise Conflict
        t = ((d // g) * pow(self.M // g, -1, m2)) % m2 if m2 > 1 else 0
        return Sunzi(self.M * m2, self.K + self.M * t)


# ---------------------------------------------------------------- THE WORD hashes
PHI = 1.6180339887498948482
PHI_32 = 2654435769
TAU = math.pi * 2
TRIB = 1.8392867552141612
SILVER = 2.4142135623730950488
GOLDEN_ANGLE = TAU / (PHI * PHI)
SZ = 1 << 16
MASK = SZ - 1

FIB = [0] * 64
FIB[0], FIB[1] = 2, 3
for _i in range(2, 64):
    FIB[_i] = FIB[_i - 1] + FIB[_i - 2]
    if FIB[_i] > (2 ** 53 - 1) / 2:
        FIB[_i] = 0
        break

HASH_NAMES = ["original", "phi", "geomean", "fibindex", "phiknuth",
              "piphi", "silver", "tribonacci", "goldenspiral", "taucircle"]


def _enc_char(c):
    o = ord(c)
    if 97 <= o <= 122:
        return o - 97
    if 65 <= o <= 90:
        return (1 << 5) | (o - 65)
    if 48 <= o <= 57:
        return (2 << 5) | (o - 48)
    if o in (32, 9, 10):
        return 3 << 5
    return 0b00011111


def _seed(b):
    return 2 + (b & 0x1F) + ((b >> 5) & 0x07) * 32


def _imul(a, b):
    r = (int(a) * int(b)) & 0xFFFFFFFF
    return r - (1 << 32) if r & 0x80000000 else r


def _nearest_fib(n):
    if n == 0:
        return 0
    best, dist = 0, abs(n - FIB[0])
    for i in range(1, 64):
        if not FIB[i]:
            break
        d = abs(n - FIB[i])
        if d < dist:
            dist, best = d, i
        if FIB[i] > n * 4:
            break
    return best


def hash_word(word, method):
    seeds = [_seed(_enc_char(c)) for c in word]
    if not seeds:
        return 0
    if method == 0:
        acc = 1
        for i, s in enumerate(seeds):
            s = max(s, 1)
            acc = _imul(acc, s) if i % 2 == 0 else max(acc // s, 1)
        return acc & MASK
    if method == 3:
        acc = 0
        for s in seeds:
            fi = _nearest_fib(s)
            acc = (acc + fi * (FIB[fi] or 1)) & MASK
        return acc
    if method == 4:
        acc = 0
        for s in seeds:
            acc = (acc + _imul(s, PHI_32 - (1 << 32))) & 0xFFFFFFFF
        return (acc >> 16) & MASK
    acc = 0.0 if method == 8 else 1.0
    for s in seeds:
        if method == 1:
            acc = (acc * PHI + s) % SZ
        elif method == 2:
            acc = math.sqrt(acc * s) * PHI % SZ
            if not math.isfinite(acc):
                acc = 1.0
        elif method == 5:
            acc = (acc + math.cos(s * math.pi / PHI) * SZ * 0.5 + SZ * 0.5) % SZ
        elif method == 6:
            acc = (acc * SILVER + s) % SZ
        elif method == 7:
            acc = (acc * TRIB + s) % SZ
        elif method == 8:
            acc = (acc + s * GOLDEN_ANGLE) % SZ
        elif method == 9:
            acc = (acc * TAU + s) % SZ
    return int(abs(acc)) & MASK


# ---------------------------------------------------------------- MAP hypervectors
D = 1024
_vcache = {}


def vsa_vec(word):
    v = _vcache.get(word)
    if v is None:
        rng = SplitMix64(fnv1a64(("vsa:" + word).encode()))
        bits = []
        while len(bits) < D:
            x = rng.next()
            bits.extend(1 if (x >> i) & 1 else -1 for i in range(64))
        v = _vcache[word] = bits[:D]
    return v


_rcache = {}


def vsa_role(word):
    """Subject-role vector: the word's vector rotated one place (the P in Multiply-Add-Permute).
    Without it, elementwise binding is commutative and S-R-O reads back as O-R-S."""
    v = _rcache.get(word)
    if v is None:
        w = vsa_vec(word)
        v = _rcache[word] = w[-1:] + w[:-1]
    return v
