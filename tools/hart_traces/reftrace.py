"""TEST ONLY. Reference retire traces in the phase 4 column format.

Columns 1-15 are exactly the phase 4 trace columns (traces/no_hazard.trace).
Columns 16-26 are added for phase 6/7 programs and are optional: a reader
that finds only 15 columns treats 16-26 as don't-care.

   1 pc  2 inst  3 trap  4 halt  5 rs1_raddr  6 rs1_rdata  7 rs2_raddr
   8 rs2_rdata  9 rd_waddr  10 rd_wdata  11 mem_op  12 mem_addr
  13 mem_mask  14 mem_wdata  15 next_pc
  16 frs1_raddr  17 frs1_rdata  18 frs2_raddr  19 frs2_rdata
  20 frs3_raddr  21 frs3_rdata  22 frd_wen  23 frd_waddr  24 frd_wdata
  25 fflags  26 mem_rdata (the raw word a load read)

Don't-care fields are written as x (phase 4 trace README):
  * rs1/rs2 only for instruction classes that read them (OP, OP-IMM, LOAD,
    STORE, BRANCH, JALR; plus integer-reading F instructions: flw/fsw base,
    fmv.w.x, fcvt.s.w[u], register-form CSR ops). Never for illegal ones.
  * rd_wdata only when rd != 0; mem_addr/mask/wdata only when mem_op != 0;
    mem_wdata only for stores (the reader compares masked lanes only).
  * frsN only for F instructions that read that FP source; frd_waddr/wdata
    only when frd_wen.

iss_to_rows() turns tools/hart_diff/iss.py output (run unmodified) into
rows. iss.py does not model a trap on a misaligned taken branch/jump
target, so programs mark such instructions in `subst`: the reference is
computed by running iss.py on an image where each is replaced by an
instruction with the same architectural effect as the trapped one (no rd
write, next pc = pc + 4, the same integer registers read), and the real
word and trap = 1 are put back in the row.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ISS = os.path.join(HERE, "..", "hart_diff", "iss.py")

HEADER = """# columns, left to right:
#
#   context for this vector (also loaded into the program image):
#    1  pc           [31:0]
#    2  inst         [31:0]
#
#   compare these against the design's outputs:
#    3  trap
#    4  halt
#    5  rs1_raddr    [4:0]
#    6  rs1_rdata    [31:0]
#    7  rs2_raddr    [4:0]
#    8  rs2_rdata    [31:0]
#    9  rd_waddr     [4:0]
#   10  rd_wdata     [31:0]
#   11  mem_op       [1:0]
#   12  mem_addr     [31:0]
#   13  mem_mask     [3:0]
#   14  mem_wdata    [31:0]
#   15  next_pc      [31:0]
#
#   phase 6/7 additions (tools/hart_traces/reftrace.py):
#   16  frs1_raddr   [4:0]
#   17  frs1_rdata   [31:0]
#   18  frs2_raddr   [4:0]
#   19  frs2_rdata   [31:0]
#   20  frs3_raddr   [4:0]
#   21  frs3_rdata   [31:0]
#   22  frd_wen
#   23  frd_waddr    [4:0]
#   24  frd_wdata    [31:0]
#   25  fflags       [4:0]
#   26  mem_rdata    [31:0]
#
# x / xx / xxxxxxxx is a don't-care field.
"""


# ---------------------------------------------------------------- decoding
# A mirror of decoder.v's legality rules (phase 4 + M + F + fcsr CSRs).
def fields(inst):
    return dict(opc=inst & 0x7F, rd=(inst >> 7) & 31, f3=(inst >> 12) & 7,
                rs1=(inst >> 15) & 31, rs2=(inst >> 20) & 31, rs3=inst >> 27,
                f7=inst >> 25, fmt=(inst >> 25) & 3, csr=inst >> 20)


def legal(inst):
    d = fields(inst)
    opc, f3, f7, rs2 = d["opc"], d["f3"], d["f7"], d["rs2"]
    rm_ok = f3 not in (5, 6)
    if inst == 0x00100073:
        return True
    if opc in (0x37, 0x17, 0x6F):
        return True
    if opc == 0x67:
        return f3 == 0
    if opc == 0x63:
        return f3 not in (2, 3)
    if opc == 0x03:
        return f3 not in (3, 6, 7)
    if opc == 0x23:
        return f3 in (0, 1, 2)
    if opc == 0x13:
        return (f3 != 1 or f7 == 0) and (f3 != 5 or f7 in (0, 0x20))
    if opc == 0x33:
        return f7 in (0, 1) or (f7 == 0x20 and f3 in (0, 5))
    if opc in (0x07, 0x27):
        return f3 == 2
    if opc == 0x53:
        return ((f7 in (0, 4, 8, 12) and rm_ok) or (f7 == 0x2C and rs2 == 0 and rm_ok) or
                (f7 == 0x10 and f3 in (0, 1, 2)) or (f7 == 0x14 and f3 in (0, 1)) or
                (f7 == 0x50 and f3 in (0, 1, 2)) or (f7 == 0x70 and rs2 == 0 and f3 in (0, 1)) or
                (f7 == 0x60 and rm_ok and rs2 in (0, 1)) or (f7 == 0x68 and rm_ok and rs2 in (0, 1)) or
                (f7 == 0x78 and rs2 == 0 and f3 == 0))
    if opc in (0x43, 0x47, 0x4B, 0x4F):
        return d["fmt"] == 0 and rm_ok
    if opc == 0x73:
        return f3 not in (0, 4) and d["csr"] in (1, 2, 3)
    return False


def int_reads(inst):
    """(reads rs1, reads rs2) by instruction class."""
    if not legal(inst):
        return False, False
    d = fields(inst)
    opc, f3, f7 = d["opc"], d["f3"], d["f7"]
    if opc in (0x33, 0x23, 0x63):
        return True, True
    if opc in (0x13, 0x03, 0x67, 0x07, 0x27):
        return True, False
    if opc == 0x53 and f7 in (0x68, 0x78):
        return True, False
    if opc == 0x73 and not (f3 & 4):
        return True, False
    return False, False


def fp_reads(inst):
    """(reads frs1, frs2, frs3), decoder.v's f_reads_frs* groups."""
    if not legal(inst):
        return False, False, False
    d = fields(inst)
    opc, f7 = d["opc"], d["f7"]
    if opc in (0x43, 0x47, 0x4B, 0x4F):
        return True, True, True
    if opc == 0x27:
        return False, True, False
    if opc != 0x53:
        return False, False, False
    r1 = f7 in (0, 4, 8, 12, 0x2C, 0x10, 0x14, 0x50, 0x70, 0x60)
    r2 = f7 in (0, 4, 8, 12, 0x10, 0x14, 0x50)
    return r1, r2, False


def is_fp_arith(inst):
    """F instructions whose result iss.py fakes (anything that rounds or
    raises flags, plus fsgnj/fmin/fmax/fclass/compares)."""
    d = fields(inst)
    if d["opc"] in (0x43, 0x47, 0x4B, 0x4F):
        return True
    if d["opc"] == 0x53 and d["f7"] not in (0x78,) and not (d["f7"] == 0x70 and d["f3"] == 0):
        return True
    return False


# ---------------------------------------------------------------- rows
def x(n):
    return "x" * n


def h(v, n):
    return "%0*x" % (n, v)


LINE = re.compile(r"^(\w{8}) (\w{8}) t(\d) h(\d) npc=(\w{8}) x(\d+)=(\w{8}) x(\d+)=(\w{8}) "
                  r"f(\d+)=(\w{8}) f(\d+)=(\w{8}) f(\d+)=(\w{8})(.*)$")


def iss_to_rows(words, subst=None, fp_mask=False):
    """Run iss.py on `words` and return trace rows (lists of column strings).

    subst: {index: substitute_word} for misaligned-target branches/jumps
    that must trap (see module docstring).
    fp_mask: for programs with FP arithmetic, mark its results (frd_wdata,
    integer rd_wdata of FP ops) and every fflags from the first such
    instruction on as don't-care, because iss.py's FP math is fake.
    """
    subst = subst or {}
    image = [subst.get(i, w) for i, w in enumerate(words)]
    with tempfile.TemporaryDirectory() as tmp:
        hexf = os.path.join(tmp, "p.hex")
        out = os.path.join(tmp, "p.trace")
        with open(hexf, "w") as f:
            f.write("".join("%08x\n" % w for w in image))
        subprocess.run([sys.executable, "-I", ISS, hexf, out], check=True)
        lines = open(out).read().splitlines()

    rows = []
    flags_unknown = False
    for ln in lines:
        m = LINE.match(ln)
        if not m:
            raise ValueError("unparsed iss line: " + ln)
        pc = int(m.group(1), 16)
        idx = (pc - 0x00400000) >> 2
        inst = words[idx]
        trap = int(m.group(3))
        halt = int(m.group(4))
        npc = int(m.group(5), 16)
        x1, x1v = int(m.group(6)), int(m.group(7), 16)
        x2, x2v = int(m.group(8)), int(m.group(9), 16)
        fsrc = [(int(m.group(10)), int(m.group(11), 16)), (int(m.group(12)), int(m.group(13), 16)),
                (int(m.group(14)), int(m.group(15), 16))]
        rest = m.group(16)
        rd = re.search(r" rd(\d+)=(\w{8})", rest)
        fd = re.search(r" fd(\d+)=(\w{8})", rest)
        ff = int(re.search(r" ff=(\w{2})", rest).group(1), 16)
        ld = re.search(r" ld\[(\w{8})\](\w)=(\w{8})", rest)
        st = re.search(r" st\[(\w{8})\](\w)=(\w{8})", rest)
        if idx in subst:
            trap = 1
        d = fields(inst)
        r1, r2 = int_reads(inst)
        f1, f2, f3r = fp_reads(inst)
        arith = fp_mask and is_fp_arith(inst) and legal(inst)
        if arith:
            flags_unknown = True

        row = [h(pc, 8), h(inst, 8), str(trap), str(halt)]
        # Integer sources. iss.py prints x<r>=<v> with r = 0 when not read.
        if r1:
            if x1 not in (0, d["rs1"]):
                raise ValueError("rs1 mismatch at %08x" % pc)
            row += [h(d["rs1"], 2), h(x1v if d["rs1"] else 0, 8)]
        else:
            row += [x(2), x(8)]
        if r2:
            if x2 not in (0, d["rs2"]):
                raise ValueError("rs2 mismatch at %08x" % pc)
            row += [h(d["rs2"], 2), h(x2v if d["rs2"] else 0, 8)]
        else:
            row += [x(2), x(8)]
        # Integer destination.
        if rd and not trap:
            v = x(8) if arith else h(int(rd.group(2), 16), 8)
            row += [h(int(rd.group(1)), 2), v]
        else:
            row += ["00", x(8)]
        # Memory.
        if ld and not trap:
            row += ["1", ld.group(1), ld.group(2), x(8)]
        elif st and not trap:
            row += ["2", st.group(1), st.group(2), st.group(3)]
        else:
            row += ["0", x(8), "x", x(8)]
        row.append(h(npc, 8))
        # FP sources.
        for rd_it, (fr, fv), name in zip((f1, f2, f3r), fsrc, ("frs1", "frs2", "frs3")):
            if rd_it and not trap:
                row += [h(fr, 2), h(fv, 8)]
            else:
                row += [x(2), x(8)]
        # FP destination.
        if fd and not trap:
            row += ["1", h(int(fd.group(1)), 2), x(8) if arith else h(int(fd.group(2), 16), 8)]
        else:
            row += ["0", x(2), x(8)]
        row.append(x(2) if flags_unknown else h(ff, 2))
        row.append(ld.group(3) if (ld and not trap) else x(8))
        rows.append(row)
    return rows


def write_trace(path, rows, title, notes=()):
    with open(path, "w", newline="\n") as f:
        f.write(HEADER)
        f.write("#\n# %s\n" % title)
        for n in notes:
            f.write("# %s\n" % n)
        f.write("# %d instructions retired. Generated by tools/hart_traces/; do not edit.\n" % len(rows))
        f.write("\n")
        for r in rows:
            f.write(" ".join(r) + "\n")


def write_hex(path, words):
    with open(path, "w", newline="\n") as f:
        f.write("".join("%08x\n" % w for w in words))
