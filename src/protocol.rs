//! The pixel strip the PolestarLink add-on paints (addon/PolestarLink/PolestarLink.lua).
//!
//! A grid of `cols` x `rows` cells anchored at the game window's top-left pixel
//! (250 x 2 cells of 3 px as shipped: a 750 x 6 px line along the top edge).
//! Each cell is a solid square carrying three bytes as its R, G, B:
//!
//! | cell | bytes                                             |
//! |------|---------------------------------------------------|
//! | 0    | magic `50 4C 4B` ("PLK")                          |
//! | 1    | magic `FF 00 FF`                                  |
//! | 2    | cols, rows, version                               |
//! | 3    | sequence, payload length low, payload length high |
//! | 4    | Fletcher-16 of the payload (a, b), 0              |
//! | 5..  | payload, three bytes a cell                       |
//!
//! The payload is a run of fields: tag byte, length byte, that many bytes.

use std::fmt;

pub const MAGIC0: [u8; 3] = [0x50, 0x4C, 0x4B];
pub const MAGIC1: [u8; 3] = [0xFF, 0x00, 0xFF];
pub const VERSION: u8 = 1;
pub const HEADER_CELLS: usize = 5;

/// How far a magic cell may be from its colour and still count. Data cells get
/// no tolerance: the checksum decides.
const MAGIC_TOLERANCE: u8 = 6;
/// The strip's first pixel is looked for this far in from the corner.
const SEARCH: usize = 48;

/// Top-down BGRA pixels, as GDI hands them over.
#[derive(Clone)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub bgra: Vec<u8>,
}

impl Image {
    pub fn new(width: usize, height: usize) -> Self {
        Image { width, height, bgra: vec![0; width * height * 4] }
    }

    pub fn rgb(&self, x: usize, y: usize) -> [u8; 3] {
        let i = (y * self.width + x) * 4;
        [self.bgra[i + 2], self.bgra[i + 1], self.bgra[i]]
    }

    #[cfg(test)]
    pub fn set_rgb(&mut self, x: usize, y: usize, rgb: [u8; 3]) {
        let i = (y * self.width + x) * 4;
        self.bgra[i] = rgb[2];
        self.bgra[i + 1] = rgb[1];
        self.bgra[i + 2] = rgb[0];
        self.bgra[i + 3] = 0xFF;
    }
}

/// Where the strip sits in an image: its first pixel and its cell size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Grid {
    pub ox: usize,
    pub oy: usize,
    pub pitch: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub seq: u8,
    pub cols: usize,
    pub rows: usize,
    pub grid: Grid,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DecodeError {
    /// No magic cells near the corner; `corner` is the pixel found there.
    NoStrip { corner: [u8; 3] },
    Geometry { cols: u8, rows: u8, version: u8 },
    OutOfView { need: (usize, usize), have: (usize, usize) },
    Length { len: usize, capacity: usize },
    Checksum,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::NoStrip { corner } => write!(
                f,
                "no Polestar Link strip along the window's top edge (the corner pixel is #{:02X}{:02X}{:02X})",
                corner[0], corner[1], corner[2]
            ),
            DecodeError::Geometry { cols, rows, version } => {
                write!(f, "strip header not understood (cols {cols}, rows {rows}, version {version})")
            }
            DecodeError::OutOfView { need, have } => write!(
                f,
                "the strip is {}x{} px but only {}x{} px of the window were captured",
                need.0, need.1, have.0, have.1
            ),
            DecodeError::Length { len, capacity } => {
                write!(f, "strip claims {len} payload bytes, more than the {capacity} it holds")
            }
            DecodeError::Checksum => write!(
                f,
                "strip found but its checksum fails (something is drawn over it, or the colours are altered on the way to the screen)"
            ),
        }
    }
}

pub fn fletcher16(data: &[u8]) -> (u8, u8) {
    let (mut a, mut b) = (0u32, 0u32);
    for &byte in data {
        a = (a + byte as u32) % 255;
        b = (b + a) % 255;
    }
    (a as u8, b as u8)
}

fn near(a: [u8; 3], b: [u8; 3]) -> bool {
    a.iter().zip(b).all(|(x, y)| x.abs_diff(y) <= MAGIC_TOLERANCE)
}

fn run(img: &Image, x: usize, y: usize, colour: [u8; 3]) -> usize {
    (x..img.width).take_while(|&x| near(img.rgb(x, y), colour)).count()
}

/// The strip's first pixel and a first estimate of its cell size, from the
/// two magic cells.
fn locate(img: &Image) -> Option<(usize, usize, f64)> {
    for oy in 0..img.height.min(SEARCH) {
        for ox in 0..img.width.min(SEARCH) {
            if !near(img.rgb(ox, oy), MAGIC0) {
                continue;
            }
            let p0 = run(img, ox, oy, MAGIC0);
            // One blended pixel may sit between two cells when they are not a
            // whole number of pixels wide.
            let mut x1 = ox + p0;
            let mut gap = 0;
            if x1 + 1 < img.width && !near(img.rgb(x1, oy), MAGIC1) {
                x1 += 1;
                gap = 1;
            }
            let p1 = run(img, x1, oy, MAGIC1);
            if p0 >= 2 && p1 >= 2 && p0.abs_diff(p1) <= 2 {
                return Some((ox, oy, (p0 + gap + p1) as f64 / 2.0));
            }
        }
    }
    None
}

fn decode_at(img: &Image, grid: Grid) -> Result<Frame, DecodeError> {
    let at = |col: usize, row: usize| -> Option<[u8; 3]> {
        let x = grid.ox + ((col as f64 + 0.5) * grid.pitch) as usize;
        let y = grid.oy + ((row as f64 + 0.5) * grid.pitch) as usize;
        (x < img.width && y < img.height).then(|| img.rgb(x, y))
    };
    let corner = img.rgb(0, 0);
    let header = |col: usize| at(col, 0).ok_or(DecodeError::NoStrip { corner });

    if !near(header(0)?, MAGIC0) || !near(header(1)?, MAGIC1) {
        return Err(DecodeError::NoStrip { corner });
    }
    let [cols, rows, version] = header(2)?;
    if cols < HEADER_CELLS as u8 || rows == 0 || version != VERSION {
        return Err(DecodeError::Geometry { cols, rows, version });
    }
    let (cols, rows) = (cols as usize, rows as usize);
    let need = (
        grid.ox + (cols as f64 * grid.pitch).ceil() as usize,
        grid.oy + (rows as f64 * grid.pitch).ceil() as usize,
    );
    if need.0 > img.width || need.1 > img.height {
        return Err(DecodeError::OutOfView { need, have: (img.width, img.height) });
    }

    let [seq, len_low, len_high] = header(3)?;
    let [sum_a, sum_b, _] = header(4)?;
    let len = len_low as usize | (len_high as usize) << 8;
    let capacity = (cols * rows - HEADER_CELLS) * 3;
    if len > capacity {
        return Err(DecodeError::Length { len, capacity });
    }

    let mut payload = Vec::with_capacity(len + 2);
    let mut cell = HEADER_CELLS;
    while payload.len() < len {
        let rgb = at(cell % cols, cell / cols).ok_or(DecodeError::Checksum)?;
        payload.extend_from_slice(&rgb);
        cell += 1;
    }
    payload.truncate(len);
    if fletcher16(&payload) != (sum_a, sum_b) {
        return Err(DecodeError::Checksum);
    }
    Ok(Frame { seq, cols, rows, grid, payload })
}

/// Finds and reads the strip. `hint` is the grid a previous frame decoded
/// with, tried first so a steady stream costs one pass.
pub fn decode(img: &Image, hint: Option<Grid>) -> Result<Frame, DecodeError> {
    if let Some(grid) = hint {
        if let Ok(frame) = decode_at(img, grid) {
            return Ok(frame);
        }
    }
    let corner = if img.width > 0 && img.height > 0 { img.rgb(0, 0) } else { [0; 3] };
    let (ox, oy, estimate) = locate(img).ok_or(DecodeError::NoStrip { corner })?;
    // The estimate is a pixel or so off when cells are not whole pixels wide,
    // which adds up across the row: walk outwards until the checksum holds.
    let first = decode_at(img, Grid { ox, oy, pitch: estimate });
    if first.is_ok() {
        return first;
    }
    for step in 1..=20 {
        for sign in [1.0, -1.0] {
            let pitch = estimate + sign * 0.05 * step as f64;
            if pitch >= 1.5 {
                if let Ok(frame) = decode_at(img, Grid { ox, oy, pitch }) {
                    return Ok(frame);
                }
            }
        }
    }
    first
}

/// Paints a strip the way the add-on does, for the tests.
#[cfg(test)]
pub fn render(payload: &[u8], seq: u8, cols: usize, rows: usize, grid: Grid, width: usize, height: usize) -> Image {
    let mut bytes = Vec::with_capacity(cols * rows * 3);
    bytes.extend_from_slice(&MAGIC0);
    bytes.extend_from_slice(&MAGIC1);
    bytes.extend_from_slice(&[cols as u8, rows as u8, VERSION]);
    bytes.extend_from_slice(&[seq, payload.len() as u8, (payload.len() >> 8) as u8]);
    let (a, b) = fletcher16(payload);
    bytes.extend_from_slice(&[a, b, 0]);
    bytes.extend_from_slice(payload);
    bytes.resize(cols * rows * 3, 0);

    let mut img = Image::new(width, height);
    for y in 0..height {
        for x in 0..width {
            // A game scene behind the strip, so nothing decodes by accident.
            let mut rgb = [(x * 7 + y * 3) as u8, (x + y * 11) as u8, (x * 5) as u8 | 1];
            if x >= grid.ox && y >= grid.oy {
                let col = ((x - grid.ox) as f64 / grid.pitch) as usize;
                let row = ((y - grid.oy) as f64 / grid.pitch) as usize;
                if col < cols && row < rows {
                    let i = (row * cols + col) * 3;
                    rgb = [bytes[i], bytes[i + 1], bytes[i + 2]];
                }
            }
            img.set_rgb(x, y, rgb);
        }
    }
    img
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload() -> Vec<u8> {
        (0..900u32).map(|i| (i * 37 % 251) as u8).collect()
    }

    fn round_trip(ox: usize, oy: usize, pitch: f64) {
        let grid = Grid { ox, oy, pitch };
        let img = render(&payload(), 42, 64, 8, grid, 640, 96);
        let frame = decode(&img, None).unwrap_or_else(|e| panic!("pitch {pitch} at {ox},{oy}: {e}"));
        assert_eq!(frame.payload, payload());
        assert_eq!((frame.seq, frame.cols, frame.rows), (42, 64, 8));
        assert_eq!(decode(&img, Some(frame.grid)).unwrap().payload, payload());
    }

    #[test]
    fn whole_pixel_cells() {
        round_trip(0, 0, 3.0);
        round_trip(0, 0, 4.0);
        round_trip(0, 0, 2.0);
    }

    #[test]
    fn offset_strip() {
        round_trip(8, 8, 3.0);
        round_trip(1, 31, 5.0);
    }

    #[test]
    fn fractional_cells() {
        round_trip(0, 0, 3.75);
        round_trip(0, 0, 4.2);
        round_trip(2, 1, 5.33);
    }

    #[test]
    fn the_strip_as_shipped() {
        let grid = Grid { ox: 0, oy: 0, pitch: 3.0 };
        let img = render(&payload(), 7, 250, 2, grid, 1600, 64);
        let frame = decode(&img, None).unwrap();
        assert_eq!((frame.cols, frame.rows, frame.payload), (250, 2, payload()));
    }

    #[test]
    fn empty_payload() {
        let img = render(&[], 0, 64, 8, Grid { ox: 0, oy: 0, pitch: 3.0 }, 640, 96);
        assert!(decode(&img, None).unwrap().payload.is_empty());
    }

    #[test]
    fn no_strip() {
        let mut img = Image::new(640, 96);
        img.set_rgb(0, 0, [1, 2, 3]);
        assert_eq!(decode(&img, None), Err(DecodeError::NoStrip { corner: [1, 2, 3] }));
    }

    #[test]
    fn damaged_cell_fails_the_checksum() {
        let mut img = render(&payload(), 1, 64, 8, Grid { ox: 0, oy: 0, pitch: 3.0 }, 640, 96);
        for y in 9..12 {
            for x in 90..93 {
                img.set_rgb(x, y, [9, 9, 9]);
            }
        }
        assert_eq!(decode(&img, None), Err(DecodeError::Checksum));
    }

    #[test]
    fn strip_cut_off_by_the_capture() {
        let img = render(&payload(), 1, 64, 8, Grid { ox: 0, oy: 0, pitch: 3.0 }, 120, 96);
        assert!(matches!(decode(&img, None), Err(DecodeError::OutOfView { .. })));
    }
}
