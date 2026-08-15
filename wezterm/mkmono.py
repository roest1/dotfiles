# /// script
# requires-python = ">=3.10"
# dependencies = ["fonttools>=4.50"]
# ///
"""Derive a monospaced Science Gothic from the upstream variable font.

    uv run wezterm/mkmono.py <ScienceGothic-variable.ttf> <outdir>

Run by hand, not at install time -- the two .ttf files it produces are
committed under wezterm/fonts/, so a fresh machine needs no python, no network
and no font tooling. Same arrangement as mise.toml and nvim/lsp-servers: one
authored generator, a generated artifact next to it. `make mono-font` re-runs
it after an upstream release.

WHY THIS EXISTS
---------------
wezterm renders a terminal on a fixed grid: every cell advances by the same
width, taken from the primary font. Science Gothic is proportional -- at
font_size 11 its 'm' asks for 0.99em and its 'l' for 0.30em against a 0.62em
cell -- so dropping it into the grid makes 'm' bleed into its neighbour while
'l' floats in twice its own width of air. It looks fine in the tab bar because
that is proportional text laid out proportionally, not a grid.

The naive fix is to squash every glyph to one advance, which wrecks the wide
letters. Science Gothic is variable with a wdth axis spanning 50-200, so
instead each glyph is taken from the width instance whose natural advance
lands closest to the cell: 'm' and 'W' come from the condensed end, 'i' and
'l' from the extended end. Every outline stays a legitimate instance of the
family. Only the handful that overflow even at wdth=50 ('%', '@') get a real
horizontal scale, and only by the amount needed.

The target advance is 0.62em because that is exactly 0xProto's, which lets the
two fonts interleave on one grid with no drift -- that is what makes the
`font_rules` in wezterm.lua work at all.

FEET
----
Instancing alone still leaves 'i' and 'l' at 23-24% ink in a cell where every
other letter fills 77-94%, which reads as broken spacing rather than as
monospace. Real monospaced faces draw the narrow glyphs wider instead of
respacing them, because on a fixed grid a narrow glyph is always going to sit
in a pool of air. The shapes below were measured off 0xProto:

    l  top-left flag + tail turning right   67% ink
    i  top-left flag + bottom serif + dot   72%
    I  symmetric top and bottom serifs      71%
    1  bottom serif, keeps its own flag     74%

Two details are load-bearing and were both learned the hard way. The top-left
flag is what separates 'l' from 'L' -- a bare stem with a flat foot IS a
capital L, and without the flag the help table read "instaLL Link Lint". And
the bend radius where the stem turns into the tail must stay small: at 0.9x
the stroke and above the stem starts curving away halfway down and reads as a
hockey stick, while a tight radius with an upturned end balls up into a blob.
0xProto keeps the stem dead straight and turns late, which is 0.4x, flat end,
no upturn.
"""
import math
import sys

from fontTools.misc.transform import Transform
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import ttProgram
from fontTools.varLib import instancer

CELL_EM = 0.62                        # 0xProto's uniform advance
WIDTHS = list(range(50, 205, 5))
CUTS = [("ScienceGothicMono.ttf", "Regular", 500), ("ScienceGothicMono-Bold.ttf", "Bold", 700)]

# glyph -> flag?  tail?  top serif?  bottom serif?  target ink fill
PLAN = {
    "l": dict(flag=True, tail=True, top=False, bottom=False, fill=0.67),
    "i": dict(flag=True, tail=False, top=False, bottom=True, fill=0.72),
    "I": dict(flag=False, tail=False, top=True, bottom=True, fill=0.71),
    "1": dict(flag=False, tail=False, top=False, bottom=True, fill=0.74),
}


def signed_area(pts):
    a = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % len(pts)]
        a += x0 * y1 - x1 * y0
    return a / 2.0


def arc(cx, cy, r, a0, a1, n=10):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * k / n)))
            for k in range(n + 1)]


def contours_of(rec):
    out, cur = [], []
    for op, args in rec.value:
        if op == "moveTo":
            if cur:
                out.append(cur)
            cur = [args[0]]
        elif op == "lineTo":
            cur.append(args[0])
        elif op in ("qCurveTo", "curveTo"):
            cur.extend([p for p in args if p is not None])
        elif op == "closePath":
            if cur:
                out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def monospace(src, wght):
    """Per-glyph width instancing onto a single advance."""
    insts = {}
    for w in WIDTHS:
        f = TTFont(src)
        instancer.instantiateVariableFont(
            f, {"wght": wght, "wdth": w, "slnt": 0, "CTRS": 0},
            inplace=True, updateFontNames=False)
        insts[w] = f

    base = insts[100]
    upm = base["head"].unitsPerEm
    target = round(CELL_EM * upm)
    order = base.getGlyphOrder()
    scaled = 0

    for gname in order:
        # Widest instance that still fits; fall back to the most condensed.
        best_w, best_adv = None, None
        for w in WIDTHS:
            adv = insts[w]["hmtx"][gname][0]
            if adv <= target and (best_adv is None or adv > best_adv):
                best_w, best_adv = w, adv
        if best_w is None:
            best_w = WIDTHS[0]

        src_f = insts[best_w]
        glyf = src_f["glyf"]
        rec = DecomposingRecordingPen(src_f.getGlyphSet())
        glyf[gname].draw(rec, glyf)

        g = glyf[gname]
        if g.numberOfContours == 0:
            base["glyf"][gname] = g
            base["hmtx"][gname] = (target, 0)
            continue

        g.recalcBounds(glyf)
        ink = g.xMax - g.xMin
        avail = target - round(0.04 * upm)      # keep a small side bearing
        sx = 1.0
        if ink > avail:
            sx = avail / ink
            scaled += 1

        dx = (target - ink * sx) / 2.0 - g.xMin * sx
        pen = TTGlyphPen(None)
        rec.replay(TransformPen(pen, Transform(sx, 0, 0, 1, dx, 0)))
        ng = pen.glyph()
        ng.recalcBounds(None)
        base["glyf"][gname] = ng
        base["hmtx"][gname] = (target, ng.xMin)

    return base, target, scaled


def add_feet(f, adv):
    glyf, hmtx, cmap = f["glyf"], f["hmtx"], f.getBestCmap()
    report = []
    for ch, spec in PLAN.items():
        gname = cmap.get(ord(ch))
        if not gname:
            continue
        g = glyf[gname]
        if g.numberOfContours == 0:
            continue
        g.recalcBounds(glyf)

        rec = DecomposingRecordingPen(f.getGlyphSet())
        g.draw(rec, glyf)
        cons = contours_of(rec)
        if not cons:
            continue

        ymin = min(p[1] for c in cons for p in c)
        # The stem is the contour standing on the baseline; for 'i' that
        # excludes the dot, whose top must not be taken for the stem's.
        stem = min(cons, key=lambda c: min(p[1] for p in c))
        clockwise = signed_area(stem) < 0
        stem_top = max(p[1] for p in stem)
        # Stem width AT THE BASELINE, not the contour bbox -- '1' carries its
        # flag in the same contour, and a serif sized off that swallows it.
        onbase = [p[0] for p in stem if abs(p[1] - ymin) < 1]
        sx0, sx1 = ((min(onbase), max(onbase)) if onbase else
                    (min(p[0] for p in stem), max(p[0] for p in stem)))
        stem_w = sx1 - sx0
        serif_h = max(120, int(stem_w * 0.9))
        target = spec["fill"] * adv
        grow = max(0.0, target - stem_w)

        out = TTGlyphPen(None)

        def poly(pts, _cw=clockwise, _out=out):
            pts = list(pts)
            if (signed_area(pts) < 0) != _cw:
                pts.reverse()
            _out.moveTo(pts[0])
            for p in pts[1:]:
                _out.lineTo(p)
            _out.closePath()

        def rect(x0, y0, x1, y1):
            poly([(x0, y0), (x0, y1), (x1, y1), (x1, y0)])

        if spec["tail"]:
            # Stem, bend and tail as ONE contour, so the stem flows into the
            # foot rather than having a shape bolted onto it.
            t = stem_w
            R = 0.40 * t
            cx, cy = sx0 + t + R, ymin + t + R
            X = sx0 + t + grow * 0.60
            pts = [(sx0, stem_top), (sx0, cy)]
            pts += arc(cx, cy, R + t, 180, 270)
            pts += [(X, ymin), (X, ymin + t)]
            pts += arc(cx, cy, R, 270, 180)
            pts += [(sx0 + t, cy), (sx0 + t, stem_top)]
            poly(pts)
            rect(sx0 - grow * 0.40, stem_top - serif_h, sx1, stem_top)
        else:
            rec.replay(out)
            mid = (sx0 + sx1) / 2.0
            if spec["bottom"]:
                rect(mid - target / 2.0, ymin, mid + target / 2.0, ymin + serif_h)
            if spec["top"]:
                ytop = max(p[1] for c in cons for p in c)
                rect(mid - target / 2.0, ytop - serif_h, mid + target / 2.0, ytop)
            if spec["flag"]:
                rect(sx0 - grow * 0.55, stem_top - serif_h, sx1, stem_top)

        ng = out.glyph()
        ng.recalcBounds(None)
        dx = (adv - (ng.xMax - ng.xMin)) / 2.0 - ng.xMin
        pen = TTGlyphPen(None)
        r2 = DecomposingRecordingPen(None)
        ng.draw(r2, None)
        r2.replay(TransformPen(pen, Transform(1, 0, 0, 1, dx, 0)))
        ng = pen.glyph()
        ng.recalcBounds(None)

        glyf[gname] = ng
        hmtx[gname] = (adv, ng.xMin)
        report.append(f"{ch}:{(ng.xMax - ng.xMin) / adv:.0%}")
    return report


def finish(f, adv, style, weight):
    order = f.getGlyphOrder()
    # Hinting was authored against the original advances and would now fight
    # the grid. The program has to be emptied, not deleted -- glyf.compile()
    # reads it unconditionally.
    for tag in ("prep", "fpgm", "cvt "):
        if tag in f:
            del f[tag]
    for gname in order:
        g = f["glyf"][gname]
        if g.numberOfContours != 0:
            prog = ttProgram.Program()
            prog.fromBytecode(b"")
            g.program = prog

    f["hhea"].advanceWidthMax = adv
    f["hhea"].minLeftSideBearing = 0
    f["hhea"].minRightSideBearing = 0
    f["post"].isFixedPitch = 1
    f["OS/2"].xAvgCharWidth = adv
    f["OS/2"].panose.bProportion = 9        # monospaced
    f["OS/2"].panose.bFamilyType = 2
    f["OS/2"].usWeightClass = weight
    sel = f["OS/2"].fsSelection
    f["OS/2"].fsSelection = (sel & ~0x60) | (0x20 if style == "Bold" else 0x40)
    if style == "Bold":
        f["head"].macStyle |= 1
    else:
        f["head"].macStyle &= ~1

    drawn = [g for g in order if f["glyf"][g].numberOfContours]
    f["head"].xMin = min(f["glyf"][g].xMin for g in drawn)
    f["head"].xMax = max(f["glyf"][g].xMax for g in drawn)

    n = f["name"]
    n.setName("Science Gothic Mono", 1, 3, 1, 0x409)
    n.setName(style, 2, 3, 1, 0x409)
    n.setName(f"Science Gothic Mono {style}", 4, 3, 1, 0x409)
    n.setName(f"ScienceGothicMono-{style}", 6, 3, 1, 0x409)

    # Kerning and per-axis metrics would reintroduce proportional spacing on a
    # fixed grid; fvar/STAT would advertise axes that no longer exist.
    for tag in ("GPOS", "kern", "HVAR", "STAT", "avar", "fvar", "gvar"):
        if tag in f:
            del f[tag]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    src, outdir = sys.argv[1], sys.argv[2].rstrip("/")

    for fname, style, weight in CUTS:
        f, adv, scaled = monospace(src, float(weight))
        feet = add_feet(f, adv)
        finish(f, adv, style, weight)
        f.save(f"{outdir}/{fname}")
        print(f"  {fname:28s} advance={adv}  scaled={scaled}  feet -> {' '.join(feet)}")


if __name__ == "__main__":
    main()
