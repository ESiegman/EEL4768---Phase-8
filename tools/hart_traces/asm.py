"""TEST ONLY. A tiny RV32IMF assembler for the directed hart programs.

The R/I/S/R4 encoders are copied from tools/hart_diff/directed.py (which is
not imported, so it can change without breaking these programs); B, J and U
formats, labels and the rest of the mnemonics are added here.

A program is a list of items:
  * an int: an instruction word
  * ("label", name): marks the address of the next instruction
  * a callable f(pc, labels) -> int: an instruction whose encoding needs a
    label (branches and jumps)
assemble() resolves labels in a second pass and returns the words.
"""

RESET = 0x00400000
DBASE = 0x10010000


def R(f7, rs2, rs1, f3, rd, op): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def I(imm, rs1, f3, rd, op): return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def S(imm, rs2, rs1, f3, op): return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | op
def R4(rs3, rs2, rs1, rm, rd, op): return (rs3 << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | op


def B(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def J(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | \
           (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def U(imm20, rd, op): return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def simm12(imm):
    """A 12-bit signed immediate (load/store offsets, addi, jalr)."""
    if not -2048 <= imm <= 2047:
        raise ValueError("immediate %d does not fit in 12 signed bits" % imm)
    return imm


# RV32I
lui = lambda rd, imm20: U(imm20, rd, 0x37)
auipc = lambda rd, imm20: U(imm20, rd, 0x17)
addi = lambda rd, rs1, imm: I(simm12(imm), rs1, 0, rd, 0x13)
slti = lambda rd, rs1, imm: I(imm, rs1, 2, rd, 0x13)
xori = lambda rd, rs1, imm: I(imm, rs1, 4, rd, 0x13)
ori = lambda rd, rs1, imm: I(imm, rs1, 6, rd, 0x13)
andi = lambda rd, rs1, imm: I(imm, rs1, 7, rd, 0x13)
slli = lambda rd, rs1, sh: I(sh, rs1, 1, rd, 0x13)
srli = lambda rd, rs1, sh: I(sh, rs1, 5, rd, 0x13)
srai = lambda rd, rs1, sh: I(0x400 | sh, rs1, 5, rd, 0x13)
add = lambda rd, a, b: R(0, b, a, 0, rd, 0x33)
sub = lambda rd, a, b: R(0x20, b, a, 0, rd, 0x33)
sll = lambda rd, a, b: R(0, b, a, 1, rd, 0x33)
slt = lambda rd, a, b: R(0, b, a, 2, rd, 0x33)
sltu = lambda rd, a, b: R(0, b, a, 3, rd, 0x33)
xor = lambda rd, a, b: R(0, b, a, 4, rd, 0x33)
srl = lambda rd, a, b: R(0, b, a, 5, rd, 0x33)
sra = lambda rd, a, b: R(0x20, b, a, 5, rd, 0x33)
or_ = lambda rd, a, b: R(0, b, a, 6, rd, 0x33)
and_ = lambda rd, a, b: R(0, b, a, 7, rd, 0x33)
lb = lambda rd, rs1, imm: I(simm12(imm), rs1, 0, rd, 0x03)
lh = lambda rd, rs1, imm: I(simm12(imm), rs1, 1, rd, 0x03)
lw = lambda rd, rs1, imm: I(simm12(imm), rs1, 2, rd, 0x03)
lbu = lambda rd, rs1, imm: I(simm12(imm), rs1, 4, rd, 0x03)
lhu = lambda rd, rs1, imm: I(simm12(imm), rs1, 5, rd, 0x03)
sb = lambda rs2, rs1, imm: S(simm12(imm), rs2, rs1, 0, 0x23)
sh = lambda rs2, rs1, imm: S(simm12(imm), rs2, rs1, 1, 0x23)
sw = lambda rs2, rs1, imm: S(simm12(imm), rs2, rs1, 2, 0x23)
jalr = lambda rd, rs1, imm: I(simm12(imm), rs1, 0, rd, 0x67)
EBREAK = 0x00100073
NOP = 0x00000013

# RV32M
mul = lambda rd, a, b: R(1, b, a, 0, rd, 0x33)
mulh = lambda rd, a, b: R(1, b, a, 1, rd, 0x33)
mulhsu = lambda rd, a, b: R(1, b, a, 2, rd, 0x33)
mulhu = lambda rd, a, b: R(1, b, a, 3, rd, 0x33)
div = lambda rd, a, b: R(1, b, a, 4, rd, 0x33)
divu = lambda rd, a, b: R(1, b, a, 5, rd, 0x33)
rem = lambda rd, a, b: R(1, b, a, 6, rd, 0x33)
remu = lambda rd, a, b: R(1, b, a, 7, rd, 0x33)

# RV32F (only what the directed programs use)
flw = lambda rd, rs1, imm: I(simm12(imm), rs1, 2, rd, 0x07)
fsw = lambda rs2, rs1, imm: S(simm12(imm), rs2, rs1, 2, 0x27)
fmvwx = lambda rd, rs1: R(0x78, 0, rs1, 0, rd, 0x53)
fmvxw = lambda rd, rs1: R(0x70, 0, rs1, 0, rd, 0x53)
fdiv = lambda rd, a, b, rm=0: R(0x0C, b, a, rm, rd, 0x53)


def li(rd, value):
    """lui + addi for any 32-bit value (two words, or one when it fits)."""
    value &= 0xFFFFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((value - lo) >> 12) & 0xFFFFF
    if hi == 0:
        return [addi(rd, 0, lo)]
    return [lui(rd, hi), addi(rd, rd, lo)] if lo else [lui(rd, hi)]


def label(name): return ("label", name)


def _branch(f3):
    def mk(rs1, rs2, target):
        return lambda pc, labels: B(labels[target] - pc, rs2, rs1, f3)
    return mk


beq, bne, blt, bge, bltu, bgeu = (_branch(f) for f in (0, 1, 4, 5, 6, 7))


def jal(rd, target):
    return lambda pc, labels: J(labels[target] - pc, rd)


def la(rd, target):
    """auipc + addi to a label (two words)."""
    def hi(pc, labels):
        off = labels[target] - pc
        lo = off & 0xFFF
        lo = lo - 0x1000 if lo >= 0x800 else lo
        return auipc(rd, ((off - lo) >> 12) & 0xFFFFF)

    def lo_(pc, labels):
        off = labels[target] - (pc - 4)
        lo = off & 0xFFF
        lo = lo - 0x1000 if lo >= 0x800 else lo
        return addi(rd, rd, lo)
    return [hi, lo_]


def flatten(items):
    out = []
    for it in items:
        if isinstance(it, list):
            out.extend(flatten(it))
        else:
            out.append(it)
    return out


def assemble(items, base=RESET):
    items = flatten(items)
    labels, pc = {}, base
    for it in items:
        if isinstance(it, tuple):
            labels[it[1]] = pc
        else:
            pc += 4
    words, pc = [], base
    for it in items:
        if isinstance(it, tuple):
            continue
        words.append((it(pc, labels) if callable(it) else it) & 0xFFFFFFFF)
        pc += 4
    return words, labels
