import Foundation

/// SHA-512 (FIPS 180-4), in Swift puro così funziona uguale su macOS e Linux. Serve solo per l'identificatore C4 del file MHL (catena ASC MHL).
enum SHA512 {
    private static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]
    private static let initial: [UInt64] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]

    static func hash(_ data: Data) -> [UInt8] {
        var h = initial
        var message = [UInt8](data)
        let bitLength = UInt128Pair(UInt64(message.count) &* 8)
        message.append(0x80)
        while message.count % 128 != 112 { message.append(0) }
        message += [UInt8](repeating: 0, count: 8)                      // 128 bit di lunghezza: i 64 alti sono zero
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength.low >> UInt64(shift)) & 0xff)) }

        var w = [UInt64](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 128) {
            for i in 0..<16 {
                var v: UInt64 = 0
                for b in 0..<8 { v = (v << 8) | UInt64(message[chunk + i * 8 + b]) }
                w[i] = v
            }
            for i in 16..<80 {
                let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
                let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<80 {
                let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for v in h { for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(shift)) & 0xff)) } }
        return out
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    /// La lunghezza in bit dei nostri messaggi sta in 64 bit.
    private struct UInt128Pair { let low: UInt64; init(_ low: UInt64) { self.low = low } }
}

/// Identificatore C4 (SMPTE ST 2114): SHA-512 scritto in base 58 con l'alfabeto C4, 90 caratteri che iniziano con «c4».
public enum C4ID {
    private static let charset = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    public static func string(for data: Data) -> String {
        var number = SHA512.hash(data)                        // 64 byte, big-endian
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices {
                let value = remainder * 256 + Int(number[i])
                number[i] = UInt8(value / 58)
                remainder = value % 58
            }
            digits.append(charset[remainder])
        }
        let body = String(digits.reversed())
        return "c4" + String(repeating: "1", count: max(0, 88 - body.count)) + body
    }
}
