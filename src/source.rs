//! The game window, read one strip frame at a time.

use std::time::{Duration, Instant};

use anyhow::Result;

use crate::capture::{Capturer, Mode, WindowInfo};
use crate::protocol::{decode, DecodeError, Frame, Grid};

/// A miss shorter than this is a torn frame, not worth reporting.
pub const PATIENCE: Duration = Duration::from_secs(1);

/// Why there is no frame right now.
pub enum Miss {
    Window(String),
    Strip(DecodeError),
}

impl Miss {
    pub fn lines(&self) -> Vec<String> {
        match self {
            Miss::Window(why) => vec![format!("Waiting for the game: {why}.")],
            Miss::Strip(DecodeError::NoStrip { corner }) => vec![
                "Waiting for the Polestar Link strip along the top edge of the game window.".to_string(),
                format!("(the corner pixel is #{:02X}{:02X}{:02X})", corner[0], corner[1], corner[2]),
                String::new(),
                "If the add-on is not installed: polestar-plus install, then restart the game.".to_string(),
                "If it is: /plk on in the game, and keep the top-left of the window on screen.".to_string(),
            ],
            Miss::Strip(why) => vec![format!("Waiting: {why}.")],
        }
    }

    /// One short line, for where there is no room for `lines`.
    pub fn brief(&self) -> String {
        match self {
            Miss::Window(why) => format!("Waiting for the game: {why}"),
            Miss::Strip(DecodeError::NoStrip { .. }) => "Waiting for the Polestar Link strip (/plk on in the game)".to_string(),
            Miss::Strip(why) => format!("Waiting: {why}"),
        }
    }
}

pub struct Source {
    capturer: Capturer,
    forced: Option<Mode>,
    mode: Mode,
    grid: Option<Grid>,
    tried_other: Instant,
}

impl Source {
    /// `title` is the game window's title; `capture` pins one way of
    /// capturing, `None` picks whichever reads.
    pub fn new(title: &str, capture: Option<Mode>) -> Result<Self> {
        Ok(Source {
            capturer: Capturer::new(title)?,
            forced: capture,
            mode: capture.unwrap_or(Mode::Screen),
            grid: None,
            tried_other: Instant::now() - PATIENCE,
        })
    }

    fn read(&mut self, mode: Mode) -> Result<Frame, Miss> {
        let image = self.capturer.grab(mode).map_err(|e| Miss::Window(e.to_string()))?;
        let frame = decode(&image, self.grid).map_err(Miss::Strip)?;
        self.mode = mode;
        self.grid = Some(frame.grid);
        Ok(frame)
    }

    pub fn poll(&mut self) -> Result<Frame, Miss> {
        let miss = match self.read(self.mode) {
            Ok(frame) => return Ok(frame),
            Err(miss) => miss,
        };
        // The other way of capturing costs more (the whole window's picture),
        // so while nothing reads it is tried once a second, not every poll.
        if self.forced.is_none() && matches!(miss, Miss::Strip(_)) && self.tried_other.elapsed() >= PATIENCE {
            self.tried_other = Instant::now();
            let other = if self.mode == Mode::Screen { Mode::Window } else { Mode::Screen };
            if let Ok(frame) = self.read(other) {
                return Ok(frame);
            }
        }
        Err(miss)
    }

    /// Where the game window's picture is on the desktop.
    pub fn window(&mut self) -> Result<WindowInfo> {
        self.capturer.info()
    }

    /// The game is the window the player is typing into.
    pub fn focused(&mut self) -> bool {
        self.capturer.focused()
    }
}
