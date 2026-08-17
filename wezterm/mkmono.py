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

    l  top-left flag + tail turning right        67% ink
    i  top-left flag + bottom serif + dot        72%
    j  top-left flag + tail turning left + dot   62%
    I  symmetric top and bottom serifs           71%
    1  bottom serif, keeps its own flag          74%

Two details are load-bearing and were both learned the hard way. The top-left
flag is what separates 'l' from 'L' -- a bare stem with a flat foot IS a
capital L, and without the flag the help table read "instaLL Link Lint". And
the bend radius where the stem turns into the tail must stay small: at 0.9x
the stroke and above the stem starts curving away halfway down and reads as a
hockey stick, while a tight radius with an upturned end balls up into a blob.
0xProto keeps the stem dead straight and turns late, which is 0.4x, flat end,
no upturn.

'j' is in that table for the opposite reason to the others, and it is the one
glyph the instance pick above gets wrong. Its tail hangs to the LEFT of the
origin -- xMin reaches -595 at wdth=200 -- so the advance never counts it, the
selector reads 812 against a 1240 cell and takes the most extended cut on the
axis. What the width axis stretches is precisely the tail: the stem is 285.65
units at every wdth, while the tail's reach grows from 285 at wdth=50 to 868
at wdth=200. That produced a stem pinned to the right cell wall above a foot
spanning 93% of the cell, with the dot sat directly over the stem so it read
as one broken vertical -- which is a bare stem with a flat foot, i.e. exactly
the backwards-capital-L failure the flag exists to prevent on 'l'. Bold was
worse again: 1308 units of ink against the 1160 budget, so it also came back
squashed to 0.887 and its stem no longer matched 'i' and 'l'.

Hence two things. The tail is redrawn here rather than taken from the axis,
mirroring 'l' -- and since 'j' and 'l' keep nothing from the instance but the
stem and the dot, neither of which moves with wdth, monospace() sources them
from wdth=100 and never scales them. The reach fractions differ because the
sides do: on 'l' the flag goes left and the tail right, so the two split the
growth between them, while on 'j' both go left and the tail alone spends it.
"""
import math
import sys

from fontTools.misc.transform import Transform
from fontTools.pens.recordingPen import DecomposingRecordingPen, replayRecording
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import ttProgram
from fontTools.varLib import instancer

CELL_EM = 0.62                        # 0xProto's uniform advance
WIDTHS = list(range(50, 205, 5))
CUTS = [("ScienceGothicMono.ttf", "Regular", 500), ("ScienceGothicMono-Bold.ttf", "Bold", 700)]

# flag and tail are reach fractions -- how much of `grow`, the ink the glyph is
# short of its fill target, each feature spends. The flag always reaches left,
# because a top-LEFT flag is the whole point of it; the tail is signed, turning
# right when positive and left when negative. 0 means the feature is absent.
# Off 0xProto's 'j': a 196-unit stem with 573 of growth, spending 568 on the
# tail and 452 on the flag -- both leftward, so the tail alone sets the extent.
#
# glyph -> flag reach  tail reach  top serif?  bottom serif?  target ink fill
PLAN = {
    "l": dict(flag=0.40, tail=+0.60, top=False, bottom=False, fill=0.67),
    "j": dict(flag=0.79, tail=-1.00, top=False, bottom=False, fill=0.62),
    "i": dict(flag=0.55, tail=0, top=False, bottom=True, fill=0.72),
    "I": dict(flag=0, tail=0, top=True, bottom=True, fill=0.71),
    "1": dict(flag=0, tail=0, top=False, bottom=True, fill=0.74),
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


def cross(pts, y):
    """Left and right edge of a contour at height y."""
    xs = []
    for i in range(len(pts)):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % len(pts)]
        if (y0 > y) != (y1 > y):
            xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
    return (min(xs), max(xs)) if xs else None


def contours_of(rec):
    """One (points, ops) pair per contour.

    The points are for measuring and are flat -- control points are treated as
    on-curve, which is exact on a stem and close enough elsewhere. The ops are
    the untouched recording, so a contour that is kept rather than measured --
    'j's dot, the one thing to survive its redraw -- goes back as the curves it
    actually is, not as a polygon of its control points.
    """
    out, pts, ops = [], [], []
    for op, args in rec.value:
        if op == "moveTo":
            if pts:
                out.append((pts, ops))
            pts, ops = [args[0]], [(op, args)]
            continue
        ops.append((op, args))
        if op == "lineTo":
            pts.append(args[0])
        elif op in ("qCurveTo", "curveTo"):
            pts.extend([p for p in args if p is not None])
        elif op == "closePath":
            if pts:
                out.append((pts, ops))
            pts, ops = [], []
    if pts:
        out.append((pts, ops))
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
    cmap = base.getBestCmap()
    # add_feet() redraws these two outright, keeping only the stem and the dot,
    # and neither moves along wdth. Reading them off the axis therefore buys
    # nothing and costs: 'j' hides its tail behind its advance, so the pick
    # below lands on wdth=200 and the Bold cut arrives 1308 units wide against
    # an 1160 budget -- squashed 11%, stem and dot included, before the feet
    # are ever sized from it. Take them from the natural instance instead.
    redrawn = {cmap[ord(ch)] for ch, spec in PLAN.items()
               if spec["tail"] and ord(ch) in cmap}
    scaled = 0

    for gname in order:
        if gname in redrawn:
            best_w = 100
        else:
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

        ymin = min(p[1] for c, _ in cons for p in c)
        # The stem is the contour reaching lowest; for 'i' and 'j' that
        # excludes the dot, whose top must not be taken for the stem's. The
        # rest is whatever the glyph carries besides it -- 'j' keeps its dot.
        si = min(range(len(cons)), key=lambda i: min(p[1] for p in cons[i][0]))
        stem = cons[si][0]
        rest = [op for i, (_, ops) in enumerate(cons) if i != si for op in ops]
        clockwise = signed_area(stem) < 0
        stem_top = max(p[1] for p in stem)
        if spec["tail"]:
            # 'j' has nothing to measure at the baseline -- the baseline runs
            # through its tail, so an edge-to-edge reading there returns the
            # foot. Both stems are dead straight above the bend, so take the
            # cross-section at half height; on 'l' it lands on the same two
            # numbers the baseline does.
            sx0, sx1 = cross(stem, stem_top * 0.5)
        else:
            # Stem width AT THE BASELINE, not the contour bbox -- '1' carries
            # its flag in the same contour, and a serif sized off that
            # swallows it.
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
            # foot rather than having a shape bolted onto it. `d` is the side
            # the tail turns toward, and everything below is written against
            # the stem's outer wall so the two directions share one shape:
            # 'l' turns right off its left wall, 'j' left off its right one.
            d = 1 if spec["tail"] > 0 else -1
            t = stem_w
            R = 0.40 * t
            ox = sx0 if d > 0 else sx1              # wall the tail curves off
            ix = ox + d * t                         # and the one it returns to
            cx, cy = ox + d * (t + R), ymin + t + R
            X = ox + d * (t + grow * abs(spec["tail"]))
            a0, a1 = (180, 270) if d > 0 else (0, -90)
            pts = [(ox, stem_top), (ox, cy)]
            pts += arc(cx, cy, R + t, a0, a1)
            pts += [(X, ymin), (X, ymin + t)]
            pts += arc(cx, cy, R, a1, a0)
            pts += [(ix, cy), (ix, stem_top)]
            poly(pts)
            rect(sx0 - grow * spec["flag"], stem_top - serif_h, sx1, stem_top)
            # The original outline is gone -- only what sits apart from the
            # stem survives, which is 'j's dot and, on 'l', nothing at all.
            replayRecording(rest, out)
        else:
            rec.replay(out)
            mid = (sx0 + sx1) / 2.0
            if spec["bottom"]:
                rect(mid - target / 2.0, ymin, mid + target / 2.0, ymin + serif_h)
            if spec["top"]:
                ytop = max(p[1] for c, _ in cons for p in c)
                rect(mid - target / 2.0, ytop - serif_h, mid + target / 2.0, ytop)
            if spec["flag"]:
                rect(sx0 - grow * spec["flag"], stem_top - serif_h, sx1, stem_top)

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

    # nameID 3 is the UNIQUE font identifier, and both cuts inherit the same
    # one from upstream -- two distinct fonts claiming a single ID, which is
    # the collision that makes a matcher pick by first match and hand back the
    # wrong glyphs. Keep upstream's version and vendor, replace the face name.
    uid = n.getDebugName(3) or "1.000;DETF;ScienceGothic-Regular"
    parts = uid.split(";")
    ver, vendor = (parts + ["1.000", "DETF"])[:2]
    n.setName(f"{ver};{vendor};ScienceGothicMono-{style}", 3, 3, 1, 0x409)

    # nameID 0/13/14 -- the upstream copyright and the OFL declaration -- are
    # deliberately left untouched. OFL 1.1 section 2 accepts machine-readable
    # metadata as a place to carry the notice, and wezterm/fonts/OFL.txt is the
    # standalone copy alongside it. Do not "clean up" these fields.

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
