# /// script
# requires-python = ">=3.10"
# dependencies = ["polars>=1.0"]
# ///
"""Columnar conversion for 2parquet / 2feather / 2pickle.

Invoked only by _sheet_convert in bash_productivity, never by hand:

    uv run bash/tabular.py <input> <output> <parquet|feather|pickle> [compression]

The PEP 723 header above is the whole dependency story. `uv run` reads it,
builds a cached environment and runs the script; nothing is installed into the
system, no virtualenv is managed by hand, and there is no requirements.txt to
drift. First run downloads, subsequent runs are warm.

polars is the only declared dependency, and that is deliberate: it is 215M
cached, and it alone covers parquet and feather. pickle needs pandas and
pyarrow on top, which takes the environment to 476M — so _sheet_convert adds
those with `uv run --with pandas --with pyarrow`, layered over this header, and
only when the target is pickle. Two of the three commands never pay for it.

Why not qsv or duckdb, the two tools already in play:

  qsv's prebuilt has no `to` subcommand (verified on 21.1.0 and 22.0.1). The
  gnu build does — `strings` shows `to  Convert CSVs to Parquet/PostgreSQL/
  XLSX/SQLite/Data Package` — but mise resolves the musl artifact because
  polars does not build on musl, and the gnu one does not run on RHEL 9 at all
  (`GLIBCXX_3.4.30 not found`, the same glibc floor deps.conf documents for
  tree-sitter). It also writes no feather even where it does run.

  duckdb cannot write Arrow IPC: v1.5.5 has no `arrow` COPY function and the
  extension is unpublished for linux_amd64. It writes parquet perfectly, but a
  parquet-only engine still leaves feather needing python.

So every non-python route covers parquet and stops short of feather. One
engine for all three beats two that split the work.

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

# Defaults differ by format because the formats are for different jobs.
# Parquet is what you store or hand to someone, so it defaults to zstd (which
# is also polars' own default, and the same codec `compress` reaches for).
# Feather is Arrow IPC, whose point is being memory-mappable and read back at
# once — compressing it trades away the property you chose it for, so it
# defaults to uncompressed. That is why the same frame is 3.2M as parquet and
# 17M as feather; the size difference is the trade, not a defect.
CODECS = {
    "parquet": {"zstd", "snappy", "gzip", "lz4", "brotli", "uncompressed"},
    "feather": {"uncompressed", "lz4", "zstd"},
}
DEFAULT_CODEC = {"parquet": "zstd", "feather": "uncompressed"}


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print("usage: tabular.py <input> <output> <parquet|feather|pickle> [compression]",
              file=sys.stderr)
        return 2

    src, dst, fmt = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    codec = sys.argv[4] if len(sys.argv) == 5 else ""

    if codec and fmt == "pickle":
        print("tabular.py: pickle takes no compression", file=sys.stderr)
        return 2
    if codec and codec not in CODECS.get(fmt, set()):
        allowed = " ".join(sorted(CODECS.get(fmt, set())))
        print(f"tabular.py: '{codec}' is not a {fmt} codec (allowed: {allowed})", file=sys.stderr)
        return 2
    codec = codec or DEFAULT_CODEC.get(fmt, "")

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
            df.write_parquet(dst, compression=codec)
        elif fmt == "feather":
            df.write_ipc(dst, compression=codec)
        elif fmt == "pickle":
            # pandas, deliberately. A pickled polars frame can only be read by
            # someone who has polars; `pd.read_pickle` is what anyone asking
            # for a .pkl actually expects. _sheet_convert supplies pandas and
            # pyarrow via `uv run --with` for this branch only.
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
