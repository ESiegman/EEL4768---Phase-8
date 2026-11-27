"""Exercise the production FPU with fresh RISC-V TestFloat divide and sqrt vectors."""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VECTORS = ROOT / "tools/fpu_vectors"
sys.path.insert(0, str(VECTORS))
from gen_vectors import MODES, ROUNDING, line


def generate(tool, directory, name, count):
    function, encode, _ = ROUNDING[name]
    with (directory / f"{name}.hex").open("w") as out:
        for rm, mode in enumerate(MODES):
            args = [tool, "-seed", "84768", "-level", "1", "-n", str(count),
                    "-tininessafter", "-" + mode, function]
            with subprocess.Popen(args, stdout=subprocess.PIPE, text=True) as proc:
                rows = 0
                for rows, fields in enumerate(proc.stdout, 1):
                    *operands, result, flags = (int(x, 16) for x in fields.split())
                    a, b = operands if name == "fdiv" else (operands[0], 0)
                    inst = encode(rm if rows % 2 else 7)
                    print(line(inst, a, b, 0, 0, result, rm, flags), file=out)
                if proc.wait() or rows != count:
                    raise RuntimeError(f"incomplete {function} vectors for {mode}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("testfloat_gen", type=Path)
    args = parser.parse_args()
    tool = args.testfloat_gen.resolve()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        vectors = root / "tools/fpu_vectors"
        vectors.mkdir(parents=True)
        for path in VECTORS.glob("*.hex"):
            if path.stem not in ("fdiv", "fsqrt"):
                (vectors / path.name).symlink_to(path)
        generate(tool, vectors, "fdiv", 50000)
        generate(tool, vectors, "fsqrt", 5000)
        sim = root / "sim"
        sources = [ROOT / name for name in ("fpu_tb.v", "fpu.v", "fpu_fma.v", "fpu_round.v",
                                             "fpu_divsqrt.v", "fpu_cvt.v", "fcsr.v")]
        subprocess.run(["iverilog", "-g2005", "-s", "fpu_tb", "-o", sim, *sources], check=True)
        # fpu_tb looks for ../tools/fpu_vectors relative to its run directory.
        work = root / "run"
        work.mkdir()
        run = subprocess.run(["vvp", "-n", sim], cwd=work, check=True,
                             stdout=subprocess.PIPE, text=True)
        print(run.stdout, end="")
        if "ALL TESTS PASSED" not in run.stdout.splitlines():
            raise SystemExit(1)


if __name__ == "__main__":
    main()
