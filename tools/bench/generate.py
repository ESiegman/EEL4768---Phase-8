"""Generate bounded RV32IMF loops for Phase 8 from the team's test assembler."""
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/hart_traces"))
import asm as a


def loop(body, setup=(), rounds=32):
    return [*setup, a.li(1, rounds), a.label("loop"), *body, a.addi(1, 1, -1),
            a.bne(1, 0, "loop"), a.EBREAK]


def fp_setup():
    return [a.li(2, 0x3FC00000), a.fmvwx(1, 2), a.li(3, 0x40400000), a.fmvwx(2, 3)]


def mixed(seed):
    rng = random.Random(seed)
    # Registers 1..5 hold loop control, data pointer and constants. Keep those
    # live across the loop so every seed visits memory and both branch paths.
    setup = [*fp_setup(), a.li(4, a.DBASE), a.li(5, 7), a.li(6, -43)]
    body = [a.andi(7, 1, 1), a.beq(7, 0, "mix"), a.add(6, 6, 1), a.label("mix")]
    for _ in range(24):
        rd, rs = rng.randrange(8, 16), rng.randrange(5, 16)
        ops = [a.add(rd, rs, 1), a.xori(rd, rs, -17), a.sw(rs, 4, 0),
               a.lw(rd, 4, 0), rng.choice([a.mul, a.mulh, a.div, a.remu])(rd, rs, 5),
               a.fdiv(3, 1, 2), a.R(0, 2, 1, 0, 4, 0x53), a.addi(rd, rs, 13)]
        body.append(rng.choice(ops))
    return loop([*body, a.addi(4, 4, 16)], setup, rounds=24)


def programs():
    ints = [a.andi(2, 1, 1), a.beq(2, 0, "call"), a.xori(3, 3, -1),
            a.label("call"), a.jal(5, "subroutine")]
    int_loop = [*loop(ints), a.label("subroutine"), a.add(3, 3, 1), a.jalr(0, 5, 0)]
    loads = [a.label("init"), a.sw(1, 4, 0), a.addi(4, 4, 64), a.addi(1, 1, -1),
             a.bne(1, 0, "init"), a.li(4, a.DBASE)]
    ldbr = loop([a.lw(2, 4, 0), a.andi(3, 2, 1), a.beq(3, 0, "next"),
                 a.add(5, 5, 2), a.label("next"), a.addi(4, 4, 64)],
                [a.li(4, a.DBASE), a.li(1, 64), *loads], rounds=64)
    m_init = [a.li(2, 0x80000000), a.li(3, -1), a.li(4, 0x10001)]
    fp = [a.R(0, 2, 1, 0, 3, 0x53), a.R(8, 2, 3, 1, 4, 0x53),
          a.R4(1, 2, 4, 2, 5, 0x43), a.fdiv(6, 5, 1, 7),
          a.R(0x2C, 0, 6, 7, 7, 0x53), a.R(0x60, 0, 7, 3, 7, 0x53),
          a.I(1, 0, 2, 8, 0x73), a.I(2, 1, 5, 9, 0x73)]
    return {
        "int_loop": int_loop,
        "ldbr_loop": ldbr,
        "mem_loop": loop([a.sw(1, 4, 0), a.lw(3, 4, 0), a.add(5, 5, 3),
                          a.addi(4, 4, 64)], [a.li(4, a.DBASE)], rounds=64),
        "mul_loop": loop([a.mul(4, 4, 1), a.mulh(5, 4, 2), a.mulhsu(6, 5, 2),
                          a.mulhu(7, 2, 3)], m_init),
        "div_loop": loop([a.div(5, 2, 3), a.divu(6, 2, 1), a.rem(7, 6, 4),
                          a.remu(8, 7, 1), a.div(9, 2, 0), a.rem(10, 2, 0)], m_init),
        "fp_loop": loop(fp, fp_setup()),
        **{f"mixed_{seed}": mixed(seed) for seed in (17, 41, 73)},
    }


if __name__ == "__main__":
    for name, items in programs().items():
        words, _ = a.assemble(items)
        (ROOT / "traces/bench" / f"{name}.hex").write_text(
            "".join(f"{word:08x}\n" for word in words))
