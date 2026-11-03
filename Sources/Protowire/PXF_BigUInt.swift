// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// An unsigned integer of any width, for the exact arithmetic a `pxf.BigFloat`
/// literal needs in both directions. Base 2^32, least significant limb first,
/// with no high zero limb. The costs are quadratic, which is why every caller
/// bounds its inputs first (`Hardening.maxNumericLiteralDigits`,
/// `Hardening.maxBigFloatExponent`).
struct BigUInt: Equatable {
    private(set) var limbs: [UInt32] = []

    init() {}

    init(_ value: UInt32) {
        if value != 0 { limbs = [value] }
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    /// From an unsigned big-endian magnitude.
    init(bigEndian bytes: Data) {
        var out: [UInt32] = []
        out.reserveCapacity(bytes.count / 4 + 1)
        var limb: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            limb |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                out.append(limb)
                limb = 0
                shift = 0
            }
        }
        if shift != 0 { out.append(limb) }
        self.init(limbs: out)
    }

    /// From ASCII decimal digits.
    init<S: Sequence>(decimalDigits digits: S) where S.Element == UInt8 {
        var chunk: UInt32 = 0
        var multiplier: UInt32 = 1
        for d in digits {
            chunk = chunk * 10 + UInt32(d - 48)
            multiplier *= 10
            if multiplier == 1_000_000_000 { // 10^9 fits a limb
                multiplyAdd(by: multiplier, adding: chunk)
                chunk = 0
                multiplier = 1
            }
        }
        if multiplier != 1 { multiplyAdd(by: multiplier, adding: chunk) }
    }

    private mutating func trim() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 32 - top.leadingZeroBitCount
    }

    /// The unsigned big-endian magnitude, with no leading zero byte.
    var bigEndianBytes: Data {
        var out = Data()
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            for shift: UInt32 in [24, 16, 8, 0] {
                let byte = UInt8(truncatingIfNeeded: limb >> shift)
                if byte != 0 || !out.isEmpty { out.append(byte) }
            }
        }
        return out
    }

    var decimalString: String {
        if isZero { return "0" }
        var rest = limbs
        var chunks: [UInt32] = []
        while !rest.isEmpty {
            var remainder: UInt64 = 0
            for i in rest.indices.reversed() {
                let value = remainder << 32 | UInt64(rest[i])
                rest[i] = UInt32(value / 1_000_000_000)
                remainder = value % 1_000_000_000
            }
            chunks.append(UInt32(remainder))
            while rest.last == 0 { rest.removeLast() }
        }
        var out = String(chunks[chunks.count - 1])
        for chunk in chunks.dropLast().reversed() {
            let text = String(chunk)
            out += String(repeating: "0", count: 9 - text.count) + text
        }
        return out
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        return limb < limbs.count && limbs[limb] >> UInt32(index % 32) & 1 == 1
    }

    /// Whether any bit below `index` is set.
    func hasBits(below index: Int) -> Bool {
        let whole = min(index / 32, limbs.count)
        if limbs[..<whole].contains(where: { $0 != 0 }) { return true }
        guard whole < limbs.count, index % 32 != 0 else { return false }
        return limbs[whole] & ((1 << UInt32(index % 32)) - 1) != 0
    }

    mutating func multiplyAdd(by factor: UInt32, adding addend: UInt32) {
        var carry = UInt64(addend)
        for i in limbs.indices {
            let product = UInt64(limbs[i]) * UInt64(factor) + carry
            limbs[i] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry != 0 { limbs.append(UInt32(carry)) }
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for (i, x) in a.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, y) in b.limbs.enumerated() {
                let value = UInt64(x) * UInt64(y) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    static func power(_ base: UInt32, _ exponent: Int) -> BigUInt {
        var result = BigUInt(1)
        var square = BigUInt(base)
        var e = exponent
        while e > 0 {
            if e & 1 == 1 { result = result * square }
            e >>= 1
            if e > 0 { square = square * square }
        }
        return result
    }

    static func << (a: BigUInt, count: Int) -> BigUInt {
        if a.isZero || count == 0 { return a }
        let bits = UInt32(count % 32)
        var out = [UInt32](repeating: 0, count: count / 32)
        out.reserveCapacity(a.limbs.count + count / 32 + 1)
        var carry: UInt32 = 0
        for limb in a.limbs {
            out.append(bits == 0 ? limb : limb << bits | carry)
            carry = bits == 0 ? 0 : limb >> (32 - bits)
        }
        if carry != 0 { out.append(carry) }
        return BigUInt(limbs: out)
    }

    static func >> (a: BigUInt, count: Int) -> BigUInt {
        let whole = count / 32
        guard whole < a.limbs.count else { return BigUInt() }
        let bits = UInt32(count % 32)
        var out = Array(a.limbs[whole...])
        if bits != 0 {
            for i in out.indices {
                let high = i + 1 < out.count ? out[i + 1] << (32 - bits) : 0
                out[i] = out[i] >> bits | high
            }
        }
        return BigUInt(limbs: out)
    }

    /// Division with remainder (Knuth, TAOCP vol. 2, algorithm D). `divisor`
    /// is not zero.
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero)
        if limbs.count < divisor.limbs.count { return (BigUInt(), self) }
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var quotient = limbs
            var remainder: UInt64 = 0
            for i in quotient.indices.reversed() {
                let value = remainder << 32 | UInt64(quotient[i])
                quotient[i] = UInt32(value / d)
                remainder = value % d
            }
            return (BigUInt(limbs: quotient), BigUInt(limbs: [UInt32(remainder)]))
        }
        // Normalize so the divisor's top bit is set.
        let shift = divisor.limbs[divisor.limbs.count - 1].leadingZeroBitCount
        let v = (divisor << shift).limbs
        var u = (self << shift).limbs
        u += [UInt32](repeating: 0, count: limbs.count + 1 - u.count)
        let n = v.count
        let m = limbs.count - n
        var q = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32
        let top = UInt64(v[n - 1]), next = UInt64(v[n - 2])
        for j in stride(from: m, through: 0, by: -1) {
            let numerator = UInt64(u[j + n]) << 32 | UInt64(u[j + n - 1])
            var estimate = numerator / top
            var rest = numerator % top
            while estimate >= base || estimate * next > (rest << 32 | UInt64(u[j + n - 2])) {
                estimate -= 1
                rest += top
                if rest >= base { break }
            }
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let product = estimate * UInt64(v[i]) + carry
                carry = product >> 32
                let t = Int64(u[i + j]) - borrow - Int64(product & 0xFFFF_FFFF)
                u[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = t < 0 ? 1 : 0
            }
            let t = Int64(u[j + n]) - borrow - Int64(carry)
            u[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {
                estimate -= 1
                var addCarry: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(u[i + j]) + UInt64(v[i]) + addCarry
                    u[i + j] = UInt32(truncatingIfNeeded: sum)
                    addCarry = sum >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + addCarry)
            }
            q[j] = UInt32(estimate)
        }
        return (BigUInt(limbs: q), BigUInt(limbs: Array(u[0..<n])) >> shift)
    }

    /// `self`, rounded to `bits` bits, ties to even: the result is the
    /// rounded value and how many low bits it dropped. `sticky` says the true
    /// value is a little above `self`. A value of `bits` bits or fewer comes
    /// back as it is.
    func rounded(toBits bits: Int, sticky: Bool = false) -> (value: BigUInt, dropped: Int) {
        let width = bitWidth
        guard width > bits else { return (self, 0) }
        var dropped = width - bits
        var kept = self >> dropped
        let half = bit(dropped - 1)
        let above = sticky || hasBits(below: dropped - 1)
        if half && (above || kept.isOdd) {
            kept.multiplyAdd(by: 1, adding: 1)
            if kept.bitWidth > bits {
                kept = kept >> 1
                dropped += 1
            }
        }
        return (kept, dropped)
    }
}
