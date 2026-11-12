//! Text for the overlay: the system's Segoe UI, rasterised by fontdue and
//! blended into a tiny-skia pixmap.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use fontdue::{Font, FontSettings, Metrics};
use tiny_skia::Pixmap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Weight {
    Regular,
    Bold,
}

/// Straight (not premultiplied) red, green, blue, alpha.
pub type Colour = [u8; 4];

pub struct Fonts {
    regular: Font,
    bold: Font,
    glyphs: HashMap<(Weight, char, u32), (Metrics, Vec<u8>)>,
}

fn load(names: &[&str]) -> Result<Font> {
    let folder = PathBuf::from(std::env::var_os("WINDIR").unwrap_or_else(|| "C:\\Windows".into())).join("Fonts");
    for name in names {
        if let Ok(bytes) = std::fs::read(folder.join(name)) {
            if let Ok(font) = Font::from_bytes(bytes, FontSettings::default()) {
                return Ok(font);
            }
        }
    }
    Err(anyhow!("none of these fonts could be read from {}: {}", folder.display(), names.join(", ")))
}

impl Fonts {
    pub fn load() -> Result<Self> {
        Ok(Fonts {
            regular: load(&["segoeui.ttf", "arial.ttf"])?,
            bold: load(&["seguisb.ttf", "segoeuib.ttf", "arialbd.ttf"])?,
            glyphs: HashMap::new(),
        })
    }

    fn font(&self, weight: Weight) -> &Font {
        match weight {
            Weight::Regular => &self.regular,
            Weight::Bold => &self.bold,
        }
    }

    /// How far above the baseline the tallest letters reach.
    pub fn ascent(&self, weight: Weight, px: f32) -> f32 {
        self.font(weight).horizontal_line_metrics(px).map_or(px * 0.8, |m| m.ascent)
    }

    pub fn width(&self, weight: Weight, px: f32, text: &str) -> f32 {
        let font = self.font(weight);
        let mut width = 0.0;
        let mut previous = None;
        for ch in text.chars() {
            if let Some(previous) = previous {
                width += font.horizontal_kern(previous, ch, px).unwrap_or(0.0);
            }
            width += font.metrics(ch, px).advance_width;
            previous = Some(ch);
        }
        width
    }

    /// `text` cut to fit `max` pixels, ending in an ellipsis when cut.
    pub fn fit(&self, weight: Weight, px: f32, text: &str, max: f32) -> String {
        if self.width(weight, px, text) <= max {
            return text.to_string();
        }
        let mut kept = String::new();
        for ch in text.chars() {
            kept.push(ch);
            if self.width(weight, px, &format!("{}…", kept.trim_end())) > max {
                kept.pop();
                break;
            }
        }
        format!("{}…", kept.trim_end())
    }

    /// `text` broken at spaces into at most `lines` lines of `max` pixels,
    /// the last one cut with an ellipsis when there is more.
    pub fn wrap(&self, weight: Weight, px: f32, text: &str, max: f32, lines: usize) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut line = String::new();
        let mut words = text.split_whitespace().peekable();
        while let Some(word) = words.next() {
            let candidate = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
            if line.is_empty() || self.width(weight, px, &candidate) <= max {
                line = candidate;
                continue;
            }
            if out.len() + 1 == lines {
                // No room for another line: everything left goes on this one, cut.
                let rest: Vec<&str> = std::iter::once(word).chain(words).collect();
                out.push(self.fit(weight, px, &format!("{line} {}", rest.join(" ")), max));
                return out;
            }
            out.push(std::mem::replace(&mut line, word.to_string()));
        }
        if !line.is_empty() {
            out.push(self.fit(weight, px, &line, max));
        }
        out
    }

    /// Draws `text` with its baseline at `baseline`, starting at `x`.
    pub fn draw(&mut self, pixmap: &mut Pixmap, weight: Weight, px: f32, x: f32, baseline: f32, colour: Colour, text: &str) {
        let (width, height) = (pixmap.width() as i32, pixmap.height() as i32);
        let mut pen = x;
        let mut previous = None;
        for ch in text.chars() {
            if let Some(previous) = previous {
                pen += self.font(weight).horizontal_kern(previous, ch, px).unwrap_or(0.0);
            }
            previous = Some(ch);
            let key = (weight, ch, px.to_bits());
            if !self.glyphs.contains_key(&key) {
                let glyph = self.font(weight).rasterize(ch, px);
                self.glyphs.insert(key, glyph);
            }
            let (metrics, coverage) = &self.glyphs[&key];
            let left = pen.round() as i32 + metrics.xmin;
            let top = baseline.round() as i32 - metrics.ymin - metrics.height as i32;
            let data = pixmap.data_mut();
            for row in 0..metrics.height as i32 {
                let y = top + row;
                if y < 0 || y >= height {
                    continue;
                }
                for col in 0..metrics.width as i32 {
                    let x = left + col;
                    if x < 0 || x >= width {
                        continue;
                    }
                    let cover = coverage[(row * metrics.width as i32 + col) as usize] as u32;
                    if cover == 0 {
                        continue;
                    }
                    // Source-over on premultiplied pixels.
                    let alpha = colour[3] as u32 * cover / 255;
                    let i = ((y * width + x) * 4) as usize;
                    for c in 0..3 {
                        data[i + c] = ((colour[c] as u32 * alpha + data[i + c] as u32 * (255 - alpha)) / 255) as u8;
                    }
                    data[i + 3] = (alpha + data[i + 3] as u32 * (255 - alpha) / 255) as u8;
                }
            }
            pen += metrics.advance_width;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_and_wraps() {
        let fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let text = "Kill Greater Plainstrider or Ornery Plainstrider for Plainstrider Beak";
        let (weight, px, max) = (Weight::Regular, 14.0, 200.0);

        assert_eq!(fonts.fit(weight, px, "Short", max), "Short");
        let cut = fonts.fit(weight, px, text, max);
        assert!(cut.ends_with('…') && fonts.width(weight, px, &cut) <= max && cut.len() > 10);

        let lines = fonts.wrap(weight, px, text, max, 2);
        assert_eq!(lines.len(), 2);
        assert!(lines.iter().all(|line| fonts.width(weight, px, line) <= max));
        assert!(lines[0].starts_with("Kill Greater") && lines[1].ends_with('…'));

        let all = fonts.wrap(weight, px, text, max, 10);
        assert_eq!(all.join(" "), text, "with room, nothing is cut");
        assert!(fonts.wrap(weight, px, "", max, 2).is_empty());
    }

    #[test]
    fn draws_inside_the_pixmap_only() {
        let mut fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let mut pixmap = Pixmap::new(40, 20).unwrap();
        // Runs off every edge: must not panic, and must leave ink.
        fonts.draw(&mut pixmap, Weight::Bold, 30.0, -10.0, 18.0, [255, 255, 255, 255], "Polestar");
        assert!(pixmap.data().chunks_exact(4).any(|p| p[3] > 0));
    }
}
