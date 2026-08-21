//! Rasterising type, for the contact sheet and the legibility numbers.
//!
//! The contact sheet is ONE image, not one per row: a TUI owns the screen and
//! redraws it, so a per-row picture would be erased by the next frame. Composing
//! the whole page into a single picture and placing it once is what makes it
//! survive. The differing row widths are the comparison, not an artefact.

use fontdue::{Font, FontSettings};

pub struct Canvas {
    pub w: usize,
    pub h: usize,
    pub px: Vec<u8>, // RGB
}

impl Canvas {
    pub fn new(w: usize, h: usize, bg: [u8; 3]) -> Self {
        let mut px = Vec::with_capacity(w * h * 3);
        for _ in 0..w * h {
            px.extend_from_slice(&bg);
        }
        Self { w, h, px }
    }

    pub fn fill(&mut self, x0: usize, y0: usize, w: usize, h: usize, c: [u8; 3]) {
        for y in y0..(y0 + h).min(self.h) {
            for x in x0..(x0 + w).min(self.w) {
                let i = (y * self.w + x) * 3;
                self.px[i..i + 3].copy_from_slice(&c);
            }
        }
    }

    /// Alpha-blend one coverage bitmap. fontdue hands back 8-bit coverage, so
    /// the blend is the whole of the antialiasing.
    fn blit(&mut self, x0: i32, y0: i32, w: usize, h: usize, cov: &[u8], c: [u8; 3]) {
        for row in 0..h {
            let y = y0 + row as i32;
            if y < 0 || y as usize >= self.h {
                continue;
            }
            for col in 0..w {
                let x = x0 + col as i32;
                if x < 0 || x as usize >= self.w {
                    continue;
                }
                let a = cov[row * w + col] as u32;
                if a == 0 {
                    continue;
                }
                let i = (y as usize * self.w + x as usize) * 3;
                for (chan, src) in self.px[i..i + 3].iter_mut().zip(c.iter()) {
                    let dst = *chan as u32;
                    *chan = ((*src as u32 * a + dst * (255 - a)) / 255) as u8;
                }
            }
        }
    }

    /// Draws a string and returns the pen x it ended at.
    pub fn text(
        &mut self,
        font: &Font,
        size: f32,
        x: i32,
        baseline: i32,
        s: &str,
        c: [u8; 3],
    ) -> i32 {
        let mut pen = x as f32;
        for ch in s.chars() {
            let (m, bitmap) = font.rasterize(ch, size);
            if m.width > 0 && m.height > 0 {
                self.blit(
                    pen as i32 + m.xmin,
                    baseline - m.height as i32 - m.ymin,
                    m.width,
                    m.height,
                    &bitmap,
                    c,
                );
            }
            pen += m.advance_width;
        }
        pen as i32
    }

    pub fn to_png(&self) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut out, self.w as u32, self.h as u32);
            // The sheet is re-sent whenever the selection moves, so its size is
            // per-keystroke pty bandwidth, not a one-off.
            enc.set_compression(png::Compression::Best);
            enc.set_color(png::ColorType::Rgb);
            enc.set_depth(png::BitDepth::Eight);
            let mut w = enc.write_header().ok()?;
            w.write_image_data(&self.px).ok()?;
        }
        Some(out)
    }
}

pub fn load(data: &[u8]) -> Option<Font> {
    Font::from_bytes(data, FontSettings::default()).ok()
}

/// How different two glyphs render, as the share of inked pixels that differ.
///
/// 0/O, 1/l and l/I are the pairs people pick a coding font to keep apart, and
/// no name, weight or metric reports them. Rendering and diffing is the only
/// way to know.
pub fn distinct(font: &Font, a: char, b: char, size: f32) -> f32 {
    let (ma, ba) = font.rasterize(a, size);
    let (mb, bb) = font.rasterize(b, size);
    let w = ma.width.max(mb.width);
    let h = ma.height.max(mb.height);
    if w == 0 || h == 0 {
        return 0.0;
    }
    let at = |m: &fontdue::Metrics, bm: &Vec<u8>, x: usize, y: usize| -> bool {
        if x >= m.width || y >= m.height {
            return false;
        }
        bm[y * m.width + x] > 96
    };
    let (mut diff, mut union) = (0u32, 0u32);
    for y in 0..h {
        for x in 0..w {
            let (pa, pb) = (at(&ma, &ba, x, y), at(&mb, &bb, x, y));
            if pa || pb {
                union += 1;
            }
            if pa != pb {
                diff += 1;
            }
        }
    }
    if union == 0 {
        0.0
    } else {
        diff as f32 / union as f32
    }
}
