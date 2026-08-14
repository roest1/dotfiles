# /// script
# requires-python = ">=3.10"
# dependencies = ["polars>=1.0", "pandas>=2.0", "pyarrow>=15"]
# ///
"""Columnar conversion for 2parquet / 2feather / 2pickle.

Invoked only by _sheet_convert in bash_productivity, never by hand:

    uv run bash/tabular.py <input> <output> <parquet|feather|pickle>

The PEP 723 header above is the whole dependency story. `uv run` reads it,
builds a cached environment and runs the script; nothing is installed into the
system, no virtualenv is managed by hand, and there is no requirements.txt to
drift. First run downloads, subsequent runs are warm.

Why this exists at all, when the rest of the 2* family is a single qsv call:
qsv's prebuilt has no `to` subcommand (verified on 21.1.0 and 22.0.1 — aqua
ships the non-polars build), and duckdb, the obvious second choice, cannot
write Arrow IPC: v1.5.5 has no `arrow` COPY function and the arrow extension
is not published for linux_amd64. duckdb writes parquet perfectly, but a
parquet-only engine still leaves feather needing Python, so one engine that
does all three beats two that split the work.

Excel never reaches this script. _sheet_convert converts it with qsv first,
because calamine reads legacy BIFF .xls that every alternative here refuses,
and because Excel stores integers as doubles — a naive reader turns an id
column into 1.0, 2.0.
"""

import sys
from pathlib import Path

import polars as pl

READERS = {
    ".csv": lambda p: pl.read_csv(p),
    ".tsv": lambda p: pl.read_csv(p, separator="\t"),
    ".tab": lambda p: pl.read_csv(p, separator="\t"),
    ".txt": lambda p: pl.read_csv(p, separator="\t"),
    ".parquet": pl.read_parquet,
    ".feather": pl.read_ipc,
    ".arrow": pl.read_ipc,
    ".ipc": pl.read_ipc,
}


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: tabular.py <input> <output> <parquet|feather|pickle>", file=sys.stderr)
        return 2

    src, dst, fmt = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

    reader = READERS.get(src.suffix.lower())
    if reader is None:
        known = " ".join(sorted(READERS))
        print(f"tabular.py: cannot read '{src.suffix}' (known: {known})", file=sys.stderr)
        return 2

    try:
        df = reader(src)
    except Exception as exc:                       # noqa: BLE001 — surfaced verbatim to the shell
        print(f"tabular.py: failed reading {src}: {exc}", file=sys.stderr)
        return 1

    try:
        if fmt == "parquet":
            df.write_parquet(dst)
        elif fmt == "feather":
            df.write_ipc(dst)
        elif fmt == "pickle":
            # pandas, deliberately. A pickled polars frame can only be read by
            # someone who has polars; `pd.read_pickle` is what anyone asking
            # for a .pkl actually expects. See the warning in `h 2pickle`.
            df.to_pandas().to_pickle(dst)
        else:
            print(f"tabular.py: unknown target '{fmt}'", file=sys.stderr)
            return 2
    except Exception as exc:                       # noqa: BLE001
        print(f"tabular.py: failed writing {dst}: {exc}", file=sys.stderr)
        dst.unlink(missing_ok=True)                # never leave a truncated file that looks real
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
