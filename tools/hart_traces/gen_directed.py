#!/usr/bin/env python3
"""TEST ONLY. Writes the directed hart programs and their reference traces.

usage: gen_directed.py [out_dir]        (default: traces/directed)

For each program P it writes P.hex (instruction memory image, loaded at
0x00400000) and P.trace (reference retire trace, tools/hart_traces/
reftrace.py format). The reference comes from tools/hart_diff/iss.py, run
unmodified. Data memory starts all zero; programs address it from
x10 = 0x10010000.

Programs (see each function):
  control      branches of every type taken / not taken, forward and
               backward loops, back-to-back branches, jal/jalr call and
               return, jalr with an odd target and with a base from a load
               miss, a branch whose operands come from a load miss
  traps        illegal encodings and misaligned loads/stores of every size
               (flw/fsw included), each followed by instructions that read
               what it would have changed
  trap_jump    taken branches/jumps to a misaligned target (trap, next pc =
               pc + 4, no link written) and a not-taken one (no trap).
               iss.py does not model this trap; see reftrace.py `subst`
  rename       WAW/WAR on one register, x0 as a destination (ALU, lui, load),
               long dependent chains, one register read twice, a register
               renamed again while its consumers wait on a load miss
  memory       store/load to the same word, same word other bytes, other
               lines, conflicting lines (write-backs), a load miss followed
               by stores to its line, pointer loads, flw/fsw. Ends with a
               flush loop (32 KB of loads at 0x10018000), so main memory
               must equal the stores afterwards for every cache config used
  mext         mul/mulh/mulhsu/mulhu/div/divu/rem/remu, divide by zero and
               overflow, dependents and independent work behind a divide
  witness_load a load miss followed by independent ALU ops
  witness_div  a divide (holds the ALU) followed by load hits
  witness_fdiv an fdiv followed by independent integer ops. FP math in
               iss.py is fake, so the fdiv result and every fflags from it
               on are don't-cares in the reference (nothing reads f3)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from asm import *  # noqa: E402,F401,F403
import reftrace  # noqa: E402

BASE = [lui(10, 0x10010)]          # x10 = 0x10010000


def control():
    p = BASE + [
        li(1, 5), li(2, -3), li(3, 5), li(4, 0x80000000), li(5, 0x7FFFFFFF),
        # Every type, taken and not taken. x20 collects one bit per path.
        beq(1, 3, "c1"), addi(20, 20, 1), label("c1"), addi(20, 20, 2),
        beq(1, 2, "c2"), addi(20, 20, 4), label("c2"),
        bne(1, 2, "c3"), addi(20, 20, 8), label("c3"),
        bne(1, 3, "c4"), addi(20, 20, 16), label("c4"),
        blt(2, 1, "c5"), addi(20, 20, 32), label("c5"),
        blt(1, 2, "c6"), addi(20, 20, 64), label("c6"),
        bge(1, 2, "c7"), addi(20, 20, 128), label("c7"),
        bge(2, 1, "c8"), addi(20, 20, 256), label("c8"),
        bltu(1, 2, "c9"), addi(20, 20, 512), label("c9"),
        bltu(2, 1, "c10"), addi(20, 20, 1024), label("c10"),
        bgeu(4, 5, "c11"), addi(20, 20, -1), label("c11"),
        bgeu(5, 4, "c12"), addi(20, 20, -2), label("c12"),
        bge(4, 5, "c13"), addi(20, 20, -4), label("c13"),
        blt(4, 5, "c14"), addi(20, 20, -8), label("c14"),
        # Backward loops (bne, blt).
        li(6, 4), label("loop1"), addi(6, 6, -1), addi(21, 21, 3), bne(6, 0, "loop1"),
        li(7, 0), li(8, 3), label("loop2"), addi(7, 7, 1), blt(7, 8, "loop2"),
        # Back-to-back branches.
        beq(0, 0, "bb1"), label("bb1"), bne(0, 0, "bad"), blt(0, 1, "bb2"), NOP,
        label("bb2"), bgeu(0, 1, "bad"), beq(1, 3, "bb3"), addi(20, 20, 99), label("bb3"),
        # Call and return through jal/jalr.
        jal(1, "func"), addi(22, 1, 0), jal(0, "after_func"),
        label("func"), addi(23, 23, 7), jalr(0, 1, 0),
        label("after_func"),
        # jalr with an odd target (bit 0 is cleared), by register and by imm.
        la(5, "t_odd"), addi(5, 5, 1), jalr(6, 5, 0), addi(20, 20, 1000),
        label("t_odd"), addi(24, 6, 0),
        la(9, "t_odd2"), jalr(7, 9, 1), addi(20, 20, 1001), label("t_odd2"), addi(25, 7, 0),
        # jalr whose (odd) base comes from a load that misses: the store
        # writes through without allocating, so the load misses.
        la(11, "t_ld"), addi(11, 11, 1), sw(11, 10, 0x400), lw(12, 10, 0x400), jalr(13, 12, 0),
        addi(20, 20, 2000), label("t_ld"), add(25, 13, 0),
        # A branch on a load miss, taken and not taken.
        li(14, 77), sw(14, 10, 0x500), lw(15, 10, 0x500), beq(15, 14, "t_br"), addi(20, 20, 3),
        label("t_br"), lw(16, 10, 0x600), bne(16, 0, "bad"), addi(26, 16, 1),
        # auipc, and jal backward.
        auipc(27, 0), auipc(28, 1),
        jal(0, "fwd"), label("back"), addi(29, 29, 5), jal(0, "done"),
        label("fwd"), jal(30, "back"),
        label("done"), add(31, 20, 21), sw(31, 10, 0), sw(20, 10, 4),
        EBREAK,
        label("bad"), addi(20, 20, 1), EBREAK,
    ]
    return p, {}, False


def traps():
    p = BASE + [
        li(5, 0x11223344), sw(5, 10, 0), li(6, 0x55667788), sw(6, 10, 4),
        li(31, 0x1234), li(9, 99), li(12, 0x777), li(13, 0x888), li(14, 0x999), li(15, 0xAAA),
        li(16, 0xBBB), li(17, 0x1717), li(18, 0x1818), li(19, 0x1919),
        fmvwx(0, 6), fmvwx(1, 5),
        # Illegal encodings, each with an rd field that names a live register.
        0x00000000, 0xFFFFFFFF, addi(20, 31, 0),
        R(0x20, 2, 1, 1, 9, 0x33), addi(21, 9, 1),          # sll with funct7 0x20
        I(0x400 | 3, 1, 1, 12, 0x13), addi(22, 12, 1),      # slli with funct7 0x20
        I(0, 10, 3, 13, 0x03), addi(23, 13, 1),             # ld (funct3 011)
        S(0, 5, 10, 3, 0x23), lw(24, 10, 0),                # sd (funct3 011)
        B(8, 0, 0, 2), addi(25, 0, 1),                      # branch funct3 010
        I(8, 0, 1, 14, 0x67), addi(26, 14, 1),              # jalr funct3 001
        0x00000073, 0x0000000F,                             # ecall, fence
        I(0x004, 0, 2, 15, 0x73), addi(27, 15, 1),          # CSR address 4
        R(0, 2, 1, 5, 16, 0x53), addi(28, 16, 1),           # fadd.s rm 101
        # Misaligned loads of every size, then readers of their rd.
        lh(17, 10, 1), lhu(18, 10, 3), lw(19, 10, 1), lw(19, 10, 2), lw(19, 10, 3),
        add(29, 17, 18), add(30, 19, 29),
        flw(1, 10, 2), fmvxw(20, 1),
        # Aligned neighbors of the same sizes still work.
        lb(21, 10, 3), lbu(22, 10, 1), lh(23, 10, 2), lhu(24, 10, 6),
        # Misaligned stores of every size, then loads of what they'd change.
        sh(6, 10, 1), sw(6, 10, 2), sw(6, 10, 3), sw(6, 10, 5), fsw(0, 10, 1), fsw(0, 10, 6),
        lw(25, 10, 0), lw(26, 10, 4),
        # A trapping load whose (misaligned) base comes from a load.
        addi(27, 10, 2), sw(27, 10, 0x10), lw(27, 10, 0x10), lw(28, 27, 0), add(29, 28, 27),
        # sb never traps.
        sb(6, 10, 3), lw(29, 10, 0),
        EBREAK,
    ]
    return p, {}, False


def trap_jump():
    # Words whose taken target is misaligned; iss.py runs the substitute.
    p = BASE + [
        li(1, 0x111), li(3, 0x333), li(8, 0x888),
        label("j1"), lambda pc, lb: J(6, 1), addi(2, 1, 0),           # jal to pc+6
        la(5, "tgt"), addi(5, 5, 2),
        label("j2"), jalr(3, 5, 0), addi(4, 3, 0),                     # jalr to tgt+2
        la(6, "tgt"),
        label("j3"), jalr(7, 6, 2), addi(9, 7, 0),                     # jalr imm 2
        label("j4"), B(6, 0, 0, 0), addi(11, 0, 1),                    # beq taken, pc+6
        label("j5"), B(6, 0, 0, 1), addi(12, 0, 2),                    # bne not taken
        label("j6"), B(-2, 0, 0, 5), addi(13, 0, 3),                   # bge taken, pc-2
        li(14, 5), li(15, 9),
        label("j7"), lambda pc, lb: B(10, 15, 14, 4), addi(16, 0, 4),  # blt taken, pc+10
        jal(8, "tgt"), addi(17, 0, 5),
        label("tgt"), addi(18, 8, 0), NOP, NOP,
        EBREAK,
    ]
    words, labels = assemble(p)
    at = lambda name: (labels[name] - RESET) >> 2
    subst = {
        at("j1"): addi(0, 0, 0),
        at("j2"): addi(0, 5, 0),
        at("j3"): addi(0, 6, 0),
        at("j4"): add(0, 0, 0),
        at("j6"): add(0, 0, 0),
        at("j7"): add(0, 14, 15),
    }
    return p, subst, False


def rename():
    p = BASE + [
        # WAW on one register, then it is read twice by one instruction.
        addi(5, 0, 1), addi(5, 0, 2), addi(5, 0, 3), add(6, 5, 5),
        # WAR.
        li(7, 10), add(8, 7, 7), addi(7, 0, 20), add(9, 8, 7),
        # x0 as a destination: ALU, lui, load; then x0 is still 0.
        addi(0, 0, 5), add(0, 7, 7), lui(0, 0x12345), sw(7, 10, 0), lw(0, 10, 0), add(11, 0, 0),
        addi(11, 11, 0),
        # A long dependent chain.
        addi(12, 0, 1)] + [addi(12, 12, 1) for _ in range(12)] + [
        slli(12, 12, 3), xor(12, 12, 9), sub(12, 12, 8), sra(12, 12, 5), or_(12, 12, 6),
        # A chain through memory.
        sw(12, 10, 8), lw(13, 10, 8), addi(13, 13, 1), sw(13, 10, 8), lw(14, 10, 8), addi(14, 14, 1),
        # Same register read twice.
        add(15, 12, 12), sub(16, 12, 12), xor(17, 13, 13), and_(18, 14, 14),
        # WAW behind a long-latency producer: the younger write must win.
        div(19, 7, 6), addi(19, 0, 5), add(20, 19, 19),
        # A register renamed again while its consumer waits on a load miss.
        lw(21, 10, 0x700), addi(22, 21, 1), addi(21, 0, 7), addi(23, 21, 1), add(24, 22, 23),
        # WAR on a store's data register.
        addi(25, 0, 0x55), sw(25, 10, 12), addi(25, 0, 0x66), lw(26, 10, 12), add(27, 25, 26),
        # Many writers of one register in flight at once.
        lw(28, 10, 0x780)] + [addi(28, 28, 1) for _ in range(9)] + [add(29, 28, 28),
        EBREAK,
    ]
    return p, {}, False


def memory():
    flush = [lui(5, 0x10018), li(6, 2048),
             label("flush"), lw(0, 5, 0), addi(5, 5, 16), addi(6, 6, -1), bne(6, 0, "flush")]
    p = BASE + [
        li(5, 0xA1B2C3D4), li(7, 0xEE), li(12, 0xBEEF), li(6, 0x0F1E2D3C),
        # Store then load, same word.
        sw(5, 10, 0), lw(8, 10, 0),
        # Same word, other bytes and halves.
        sb(7, 10, 1), lw(9, 10, 0), lbu(11, 10, 1), lb(13, 10, 1), lb(14, 10, 3),
        sh(12, 10, 2), lw(15, 10, 0), lhu(16, 10, 2), lh(17, 10, 2), lh(18, 10, 0),
        # Four sb into one word, then lw.
        sb(5, 10, 4), sb(6, 10, 5), sb(7, 10, 6), sb(12, 10, 7), lw(19, 10, 4),
        sh(5, 10, 8), sh(6, 10, 10), lw(20, 10, 8),
        # Another line.
        sw(6, 10, 0x100), lw(21, 10, 0x100), lw(22, 10, 0),
        # A load miss followed by stores to its line and others.
        lw(23, 10, 0x600), sw(5, 10, 0x604), sw(5, 10, 0x700), sw(23, 10, 0x704),
        lw(24, 10, 0x604), lw(25, 10, 0x704), lw(26, 10, 0x600),
        # Store, load, store, load the same byte.
        sb(5, 10, 0x20), lb(27, 10, 0x20), sb(27, 10, 0x21), lhu(28, 10, 0x20),
        # Back-to-back stores to one word.
        sw(5, 10, 0x30), sw(6, 10, 0x30), lw(29, 10, 0x30),
        # A pointer stored, loaded and used as a base.
        addi(30, 10, 0x40), sw(6, 10, 0x40), sw(30, 10, 0x44), lw(31, 10, 0x44), lw(31, 31, 0),
        # Negative offsets.
        addi(28, 10, 0x200), sw(5, 28, -4), lw(27, 10, 0x1FC),
        # flw/fsw move words exactly.
        fmvwx(1, 5), fsw(1, 10, 0x50), flw(2, 10, 0x50), fmvxw(26, 2), lw(25, 10, 0x50),
        fsw(2, 10, 0x54), lw(24, 10, 0x54),
        # Eight lines 4 KB apart (they conflict in every cache we test):
        # stores, then loads back after they have been evicted.
        lui(11, 0x10011)] + [sw(5 if k % 2 else 6, 11, 0x40 * k) for k in range(8)] + [
        lui(11, 0x10012), lui(13, 0x10013), lui(14, 0x10014), lui(15, 0x10015),
        sw(5, 11, 0), sw(6, 13, 0), sw(5, 14, 0), sw(6, 15, 0),
        lw(16, 11, 0), lw(17, 13, 0), lw(18, 14, 0), lw(19, 15, 0),
        lui(11, 0x10011), lw(20, 11, 0), lw(21, 11, 0x40), lw(22, 11, 0x1C0),
    ] + flush + [EBREAK]
    return p, {}, False


def mext():
    p = BASE + [
        li(5, 7), li(6, -3), li(7, 0x80000000), li(8, -1), li(9, 0),
        mul(11, 5, 6), mulh(12, 7, 7), mulhsu(13, 6, 5), mulhu(14, 8, 8),
        mulh(15, 6, 5), mulhu(16, 7, 8), mulhsu(17, 8, 8),
        div(18, 5, 6), divu(19, 5, 6), rem(20, 5, 6), remu(21, 6, 5),
        div(22, 6, 6), rem(23, 6, 5), div(24, 6, 5), remu(25, 5, 5),
        # Divide by zero and overflow.
        div(26, 5, 9), divu(27, 5, 9), rem(28, 5, 9), remu(29, 5, 9),
        div(30, 7, 8), rem(31, 7, 8), divu(30, 7, 8), remu(31, 7, 8),
        # Dependents behind M ops.
        add(11, 18, 26), mul(12, 11, 11), div(13, 12, 5), add(14, 13, 13), rem(15, 14, 6),
        mul(16, 15, 15), mul(17, 16, 16), mulhu(18, 17, 17),
        # Independent work behind a divide (fills the ROB).
        div(19, 7, 5)] + [addi(20 + (k % 4), 0, k) for k in range(10)] + [
        add(24, 19, 20), sw(24, 10, 0), lw(25, 10, 0), div(26, 25, 25),
        EBREAK,
    ]
    return p, {}, False


def witness_load():
    block = lambda off, base: [
        lw(5, 10, off),
        addi(6, 0, base + 1), addi(7, 0, base + 2), addi(8, 0, base + 3), add(9, 6, 7),
        xor(11, 8, 9), addi(12, 0, base + 5), or_(13, 6, 8),
        add(14, 5, 12),
    ]
    p = BASE + block(0x400, 0) + block(0x600, 10) + block(0x7C0, 20) + [
        sw(14, 10, 0), EBREAK]
    return p, {}, False


def witness_div():
    p = BASE + [
        li(5, 1000000), li(6, 7), sw(5, 10, 0), sw(6, 10, 4), sw(5, 10, 8),
        lw(7, 10, 0),                     # brings the line in
        div(8, 5, 6),                     # holds the ALU
        lw(9, 10, 4), lw(11, 10, 8), lw(12, 10, 0),
        add(13, 8, 9),
        div(14, 5, 6), lw(15, 10, 0), lw(16, 10, 4), add(17, 14, 15),
        EBREAK,
    ]
    return p, {}, False


def witness_fdiv():
    p = BASE + [
        li(5, 0x40490FDB), li(6, 0x402DF854),
        fmvwx(1, 5), fmvwx(2, 6),
        fdiv(3, 1, 2),
        addi(7, 0, 1), addi(8, 7, 2), addi(9, 8, 3), xor(11, 9, 7), addi(12, 0, 9),
        add(13, 11, 12), slli(14, 13, 2),
        fdiv(4, 2, 1),
        addi(15, 0, 4), addi(16, 15, 4), sw(16, 10, 0),
        EBREAK,
    ]
    return p, {}, True


PROGRAMS = [control, traps, trap_jump, rename, memory, mext,
            witness_load, witness_div, witness_fdiv]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "traces", "directed")
    os.makedirs(out, exist_ok=True)
    for fn in PROGRAMS:
        items, subst, fp_mask = fn()
        words, _ = assemble(items)
        rows = reftrace.iss_to_rows(words, subst, fp_mask)
        name = fn.__name__
        notes = [l.strip() for l in (fn.__doc__ or "").splitlines() if l.strip()]
        if subst:
            notes.append("Misaligned-target branches/jumps at word indices %s trap (iss.py run on a "
                         "substituted image, see reftrace.py)." % sorted(subst))
        if fp_mask:
            notes.append("FP arithmetic results and fflags from the first one on are don't-cares "
                         "(iss.py FP math is fake).")
        reftrace.write_hex(os.path.join(out, name + ".hex"), words)
        reftrace.write_trace(os.path.join(out, name + ".trace"), rows,
                             "%s: directed program (tools/hart_traces/gen_directed.py)" % name, notes)
        print("%-13s %4d words, %5d retired" % (name, len(words), len(rows)))


if __name__ == "__main__":
    main()
