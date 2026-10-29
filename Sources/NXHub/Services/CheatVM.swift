import Foundation

/// A cheat of an Atmosphère cheat file: [Name] (or {Name} for a master code, always on) and its opcode words
struct CheatEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let master: Bool
    let words: [UInt32]
}

enum CheatFile {
    /// Atmosphère's text format: a title line in [ ] or { }, then lines of 8-digit hex words. Words before any title belong to an unnamed master code
    static func parse(_ text: String) -> [CheatEntry] {
        var out: [CheatEntry] = []
        var name = "", master = true, words: [UInt32] = []
        func flush() { if !words.isEmpty || !name.isEmpty { out.append(CheatEntry(name: name.isEmpty ? "Master" : name, master: master, words: words)) }; words = [] }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#") { continue }
            if (line.hasPrefix("[") && line.hasSuffix("]")) || (line.hasPrefix("{") && line.hasSuffix("}")) {
                flush()
                name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                master = line.hasPrefix("{")
                continue
            }
            for tok in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                if tok.count == 8, let w = UInt32(tok, radix: 16) { words.append(w) }
            }
        }
        flush()
        return out.filter { !$0.words.isEmpty }
    }
}

/// Where the cheat VM reads and writes (the game's process), and the bases of its memory regions
protocol CheatMemory: AnyObject {
    func read(_ address: UInt64, _ width: Int) -> UInt64?
    @discardableResult func write(_ address: UInt64, _ value: UInt64, _ width: Int) -> Bool
    func pause()
    func resume()
}

struct CheatBases {
    var main: UInt64 = 0
    var heap: UInt64 = 0
    var alias: UInt64 = 0
    var aslr: UInt64 = 0
    func base(_ m: Int) -> UInt64 {
        switch m { case 0: return main; case 1: return heap; case 2: return alias; case 3: return aslr; default: return 0 }
    }
}

/// A virtual machine for Atmosphère's cheat code format (docs/features/cheats.md in Atmosphère): the opcodes are decoded once, then the program
/// (master codes first, then the cheats turned on) runs from a clean state each tick, as dmnt does 12 times a second
final class CheatVM {
    enum Op {
        case storeStatic(w: Int, m: Int, r: Int, rel: UInt64, v: UInt64)
        case beginCond(w: Int, m: Int, c: Int, useReg: Bool, r: Int, rel: UInt64, v: UInt64)
        case end, els
        case loopStart(r: Int, n: UInt64), loopEnd(r: Int)
        case loadStatic(r: Int, v: UInt64)
        case loadMem(w: Int, m: Int, r: Int, mode: Int, s: Int, rel: UInt64)
        case storeStaticReg(w: Int, r: Int, inc: Bool, useOfs: Bool, o: Int, v: UInt64)
        case legacyArith(w: Int, r: Int, op: Int, v: UInt64)
        case keyCond(mask: UInt64)
        case arith(w: Int, op: Int, dst: Int, a: Int, imm: Bool, b: Int, v: UInt64)
        case storeReg(w: Int, s: Int, r: Int, inc: Bool, ofs: Int, x: Int, rel: UInt64)
        case regCond(w: Int, c: Int, s: Int, kind: Int, m: Int, r: Int, o: Int, rel: UInt64, v: UInt64)
        case saveRestore(d: Int, s: Int, op: Int)
        case saveRestoreMask(op: Int, mask: UInt16)
        case staticReg(index: Int, r: Int)
        case extKeyCond(autoRepeat: Bool, mask: UInt64)
        case pause, resume, nop

        var opensBlock: Bool {
            switch self { case .beginCond, .keyCond, .regCond, .extKeyCond: return true; default: return false }
        }
    }

    enum DecodeError: Error { case truncated(at: Int), unknown(UInt32, at: Int) }

    var statics = [UInt64](repeating: 0, count: 256)
    private var keysBefore: UInt64 = 0

    /// Decodes a program's words; throws on an unknown opcode or a word missing at the end
    static func decode(_ words: [UInt32]) throws -> [Op] {
        var ops: [Op] = []
        var i = 0
        func next() throws -> UInt32 { guard i < words.count else { throw DecodeError.truncated(at: i) }; defer { i += 1 }; return words[i] }
        func nib(_ w: UInt32, _ shift: UInt32) -> Int { Int((w >> shift) & 0xF) }
        while i < words.count {
            let at = i
            let w0 = try next()
            var type = Int(w0 >> 28)
            if type >= 0xC { type = Int(w0 >> 24) }
            if type == 0xF0 { type = Int(w0 >> 20) }
            switch type {
            case 0x0:
                let w = nib(w0, 24), m = nib(w0, 20), r = nib(w0, 16)
                let rel = try UInt64(w0 & 0xFF) << 32 | UInt64(next())
                let v = try w == 8 ? UInt64(next()) << 32 | UInt64(next()) : UInt64(next())
                ops.append(.storeStatic(w: w, m: m, r: r, rel: rel, v: v))
            case 0x1:
                let w = nib(w0, 24), m = nib(w0, 20), c = nib(w0, 16), x = nib(w0, 12), r = nib(w0, 8)
                let rel = try UInt64(w0 & 0xFF) << 32 | UInt64(next())
                let v = try w == 8 ? UInt64(next()) << 32 | UInt64(next()) : UInt64(next())
                ops.append(.beginCond(w: w, m: m, c: c, useReg: x == 1, r: r, rel: rel, v: v))
            case 0x2:
                ops.append(nib(w0, 24) == 1 ? .els : .end)
            case 0x3:
                if nib(w0, 24) == 0 { try ops.append(.loopStart(r: nib(w0, 16), n: UInt64(next()))) }
                else { ops.append(.loopEnd(r: nib(w0, 16))) }
            case 0x4:
                try ops.append(.loadStatic(r: nib(w0, 16), v: UInt64(next()) << 32 | UInt64(next())))
            case 0x5:
                let rel = try UInt64(w0 & 0xFF) << 32 | UInt64(next())
                ops.append(.loadMem(w: nib(w0, 24), m: nib(w0, 20), r: nib(w0, 16), mode: nib(w0, 12), s: nib(w0, 8), rel: rel))
            case 0x6:
                let v = try UInt64(next()) << 32 | UInt64(next())
                ops.append(.storeStaticReg(w: nib(w0, 24), r: nib(w0, 16), inc: nib(w0, 12) != 0, useOfs: nib(w0, 8) != 0, o: nib(w0, 4), v: v))
            case 0x7:
                try ops.append(.legacyArith(w: nib(w0, 24), r: nib(w0, 16), op: nib(w0, 12), v: UInt64(next())))
            case 0x8:
                ops.append(.keyCond(mask: UInt64(w0 & 0x0FFF_FFFF)))
            case 0x9:
                let w = nib(w0, 24), imm = nib(w0, 8) != 0
                var v: UInt64 = 0
                if imm { v = try w == 8 ? UInt64(next()) << 32 | UInt64(next()) : UInt64(next()) }
                ops.append(.arith(w: w, op: nib(w0, 20), dst: nib(w0, 16), a: nib(w0, 12), imm: imm, b: nib(w0, 4), v: v))
            case 0xA:
                let ofs = nib(w0, 8)
                var rel: UInt64 = 0
                if ofs == 2 || ofs == 4 || ofs == 5 { rel = try UInt64(w0 & 0xF) << 32 | UInt64(next()) }
                ops.append(.storeReg(w: nib(w0, 24), s: nib(w0, 20), r: nib(w0, 16), inc: nib(w0, 12) != 0, ofs: ofs, x: nib(w0, 4), rel: rel))
            case 0xC0:
                let w = nib(w0, 20), c = nib(w0, 16), s = nib(w0, 12), kind = nib(w0, 8)
                var m = 0, r = 0, o = 0, rel: UInt64 = 0, v: UInt64 = 0
                switch kind {
                case 0: m = nib(w0, 4); rel = try UInt64(w0 & 0xF) << 32 | UInt64(next())
                case 1: m = nib(w0, 4); o = nib(w0, 0)
                case 2: r = nib(w0, 4); rel = try UInt64(w0 & 0xF) << 32 | UInt64(next())
                case 3: r = nib(w0, 4); o = nib(w0, 0)
                case 4: v = try w == 8 ? UInt64(next()) << 32 | UInt64(next()) : UInt64(next())
                case 5: o = nib(w0, 4)
                default: throw DecodeError.unknown(w0, at: at)
                }
                ops.append(.regCond(w: w, c: c, s: s, kind: kind, m: m, r: r, o: o, rel: rel, v: v))
            case 0xC1:
                ops.append(.saveRestore(d: nib(w0, 16), s: nib(w0, 8), op: nib(w0, 4)))
            case 0xC2:
                ops.append(.saveRestoreMask(op: nib(w0, 20), mask: UInt16(w0 & 0xFFFF)))
            case 0xC3:
                ops.append(.staticReg(index: Int((w0 >> 4) & 0xFF), r: nib(w0, 0)))
            case 0xC4:
                try ops.append(.extKeyCond(autoRepeat: nib(w0, 20) != 0, mask: UInt64(next()) << 32 | UInt64(next())))
            case 0xFF0: ops.append(.pause)
            case 0xFF1: ops.append(.resume)
            case 0xFFF:
                // Debug log: decoded for its length, then ignored
                switch nib(w0, 8) { case 0, 2: _ = try next(); default: break }
                ops.append(.nop)
            default:
                throw DecodeError.unknown(w0, at: at)
            }
        }
        return ops
    }

    private static func mask(_ w: Int) -> UInt64 { w >= 8 ? ~0 : (UInt64(1) << UInt64(w * 8)) - 1 }
    private static func validWidth(_ w: Int) -> Bool { w == 1 || w == 2 || w == 4 || w == 8 }

    private static func compare(_ a: UInt64, _ b: UInt64, _ c: Int) -> Bool {
        switch c { case 1: return a > b; case 2: return a >= b; case 3: return a < b; case 4: return a <= b; case 5: return a == b; case 6: return a != b; default: return false }
    }

    private static func arith(_ op: Int, _ a: UInt64, _ b: UInt64, _ w: Int) -> UInt64 {
        switch op {
        case 0: return a &+ b
        case 1: return a &- b
        case 2: return a &* b
        case 3: return b >= 64 ? 0 : a << b
        case 4: return b >= 64 ? 0 : a >> b
        case 5: return a & b
        case 6: return a | b
        case 7: return ~a
        case 8: return a ^ b
        case 9: return a
        case 10...13:
            if w == 4 {
                let x = Float(bitPattern: UInt32(truncatingIfNeeded: a)), y = Float(bitPattern: UInt32(truncatingIfNeeded: b))
                let r: Float = op == 10 ? x + y : op == 11 ? x - y : op == 12 ? x * y : x / y
                return UInt64(r.bitPattern)
            } else if w == 8 {
                let x = Double(bitPattern: a), y = Double(bitPattern: b)
                let r: Double = op == 10 ? x + y : op == 11 ? x - y : op == 12 ? x * y : x / y
                return r.bitPattern
            }
            return a
        default: return a
        }
    }

    /// Past the end of the block a failed condition opens: its End, or its Else when there is one (nested blocks are skipped whole)
    private static func skip(_ ops: [Op], from start: Int, toElse: Bool) -> Int {
        var depth = 0, i = start
        while i < ops.count {
            let op = ops[i]; i += 1
            if op.opensBlock { depth += 1; continue }
            switch op {
            case .end: if depth == 0 { return i }; depth -= 1
            case .els: if depth == 0 && toElse { return i }
            default: break
            }
        }
        return i
    }

    /// Runs a program once. keys: the buttons held now, as hidKeysHeld gives them (A = bit 0, …)
    func run(_ ops: [Op], bases: CheatBases, memory: CheatMemory, keys: UInt64) {
        var regs = [UInt64](repeating: 0, count: 16), saved = [UInt64](repeating: 0, count: 16), loopTop = [Int](repeating: 0, count: 16)
        var ip = 0, steps = 0
        func read(_ a: UInt64, _ w: Int) -> UInt64 { CheatVM.validWidth(w) ? (memory.read(a, w) ?? 0) & CheatVM.mask(w) : 0 }
        func write(_ a: UInt64, _ v: UInt64, _ w: Int) { if CheatVM.validWidth(w) { memory.write(a, v & CheatVM.mask(w), w) } }
        while ip < ops.count {
            steps += 1
            if steps > 200_000 { break }   // a runaway loop
            let op = ops[ip]; ip += 1
            switch op {
            case let .storeStatic(w, m, r, rel, v):
                write(bases.base(m) &+ rel &+ regs[r], v, w)
            case let .beginCond(w, m, c, useReg, r, rel, v):
                let a = bases.base(m) &+ rel &+ (useReg ? regs[r] : 0)
                if !CheatVM.compare(read(a, w), v & CheatVM.mask(w), c) { ip = CheatVM.skip(ops, from: ip, toElse: true) }
            case .els:
                ip = CheatVM.skip(ops, from: ip, toElse: false)
            case .end, .nop:
                break
            case let .loopStart(r, n):
                regs[r] = n; loopTop[r] = ip
            case let .loopEnd(r):
                regs[r] = regs[r] &- 1
                if regs[r] != 0 { ip = loopTop[r] }
            case let .loadStatic(r, v):
                regs[r] = v
            case let .loadMem(w, m, r, mode, s, rel):
                let a: UInt64
                switch mode {
                case 1: a = regs[r] &+ rel
                case 2: a = regs[s] &+ rel
                case 3: a = bases.base(m) &+ regs[s] &+ rel
                default: a = bases.base(m) &+ rel
                }
                regs[r] = read(a, w)
            case let .storeStaticReg(w, r, inc, useOfs, o, v):
                write(regs[r] &+ (useOfs ? regs[o] : 0), v, w)
                if inc { regs[r] = regs[r] &+ UInt64(w) }
            case let .legacyArith(w, r, op, v):
                regs[r] = CheatVM.arith(op, regs[r], v, w) & CheatVM.mask(w)
            case let .keyCond(mask):
                if keys & mask != mask { ip = CheatVM.skip(ops, from: ip, toElse: true) }
            case let .arith(w, op, dst, a, imm, b, v):
                regs[dst] = CheatVM.arith(op, regs[a], imm ? v : regs[b], w) & CheatVM.mask(w)
            case let .storeReg(w, s, r, inc, ofs, x, rel):
                var a = regs[r]
                switch ofs {
                case 1: a = a &+ regs[x]
                case 2: a = a &+ rel
                case 3: a = bases.base(x) &+ regs[r]
                case 4: a = bases.base(x) &+ rel
                case 5: a = bases.base(x) &+ regs[r] &+ rel
                default: break
                }
                write(a, regs[s], w)
                if inc { regs[r] = regs[r] &+ UInt64(w) }
            case let .regCond(w, c, s, kind, m, r, o, rel, v):
                let rhs: UInt64
                switch kind {
                case 0: rhs = read(bases.base(m) &+ rel, w)
                case 1: rhs = read(bases.base(m) &+ regs[o], w)
                case 2: rhs = read(regs[r] &+ rel, w)
                case 3: rhs = read(regs[r] &+ regs[o], w)
                case 4: rhs = v & CheatVM.mask(w)
                default: rhs = regs[o] & CheatVM.mask(w)
                }
                if !CheatVM.compare(regs[s] & CheatVM.mask(w), rhs, c) { ip = CheatVM.skip(ops, from: ip, toElse: true) }
            case let .saveRestore(d, s, op):
                switch op { case 0: regs[d] = saved[s]; case 1: saved[d] = regs[s]; case 2: saved[d] = 0; case 3: regs[d] = 0; default: break }
            case let .saveRestoreMask(op, m):
                for i in 0..<16 where m & (1 << i) != 0 {
                    switch op { case 0: regs[i] = saved[i]; case 1: saved[i] = regs[i]; case 2: saved[i] = 0; case 3: regs[i] = 0; default: break }
                }
            case let .staticReg(index, r):
                if index < 0x80 { regs[r] = statics[index] } else { statics[index] = regs[r] }
            case let .extKeyCond(autoRepeat, mask):
                let held = keys & mask == mask
                let fresh = held && keysBefore & mask != mask
                if !(autoRepeat ? held : fresh) { ip = CheatVM.skip(ops, from: ip, toElse: true) }
            case .pause: memory.pause()
            case .resume: memory.resume()
            }
        }
        keysBefore = keys
    }
}
