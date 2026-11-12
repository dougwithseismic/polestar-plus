//! The overlay: a small always-on-top panel over the game window. Clicks pass
//! straight through it to the game and it never takes the keyboard; it only
//! shows what the strip says.

use std::mem::zeroed;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use tiny_skia::Pixmap;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, SIZE, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{GetDC, ReleaseDC, AC_SRC_ALPHA, AC_SRC_OVER, BLENDFUNCTION};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, PeekMessageW, RegisterClassW, SetWindowPos, ShowWindow,
    TranslateMessage, UpdateLayeredWindow, HWND_TOPMOST, MSG, PM_REMOVE, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_HIDE,
    SW_SHOWNOACTIVATE, ULW_ALPHA, WM_QUIT, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    WS_EX_TRANSPARENT, WS_POPUP,
};

use crate::capture::{Surface, WindowInfo};
use crate::hud::{self, View};
use crate::model::{self, Snapshot};
use crate::source::{Source, PATIENCE};
use crate::text::Fonts;
use crate::{Options, STALE};

/// The strip lives along the game's top edge; the panel keeps clear of it.
const STRIP_CLEARANCE: i32 = 16;
/// How far in from the game window's edge the panel sits, before scaling.
const MARGIN: f32 = 56.0;

/// Where in the game window the panel sits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    TopLeft,
    Top,
    TopRight,
    Left,
    Center,
    Right,
    BottomLeft,
    Bottom,
    BottomRight,
}

impl Anchor {
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "top-left" => Anchor::TopLeft,
            "top" => Anchor::Top,
            "top-right" => Anchor::TopRight,
            "left" => Anchor::Left,
            "center" | "centre" => Anchor::Center,
            "right" => Anchor::Right,
            "bottom-left" => Anchor::BottomLeft,
            "bottom" => Anchor::Bottom,
            "bottom-right" => Anchor::BottomRight,
            _ => return None,
        })
    }

    /// 0, 1 or 2 along each axis: start, middle, end.
    fn cell(self) -> (i32, i32) {
        let i = self as i32;
        (i % 3, i / 3)
    }
}

/// The panel's top-left corner on the desktop.
pub fn place(anchor: Anchor, offset: (i32, i32), scale: f32, window: &WindowInfo, panel: (i32, i32)) -> (i32, i32) {
    let margin = (MARGIN * scale).round() as i32;
    let along = |cell: i32, room: i32, size: i32| match cell {
        0 => margin,
        1 => (room - size) / 2,
        _ => room - size - margin,
    };
    let (col, row) = anchor.cell();
    let x = along(col, window.client.0, panel.0) + offset.0;
    let y = (along(row, window.client.1, panel.1) + offset.1).max(STRIP_CLEARANCE);
    (window.origin.0 + x, window.origin.1 + y)
}

/// Where the panel goes when no offset is asked for. Polestar's own arrow
/// sits top centre, so at the top the panel starts just right of centre
/// instead of covering it; elsewhere it sits on the anchor.
pub fn beside_centre(anchor: Anchor, scale: f32, panel: (i32, i32)) -> (i32, i32) {
    match anchor {
        Anchor::Top => (panel.0 / 2 + (150.0 * scale).round() as i32, 0),
        _ => (0, 0),
    }
}

/// The size the panel is drawn at for a game window this tall.
pub fn scale_for(window: &WindowInfo) -> f32 {
    (window.client.1 as f32 / 1080.0).clamp(1.0, 2.5)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn procedure(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    DefWindowProcW(hwnd, message, wparam, lparam)
}

struct Panel {
    hwnd: HWND,
    surface: Option<Surface>,
    visible: bool,
}

impl Panel {
    fn new() -> Result<Self> {
        unsafe {
            let instance = GetModuleHandleW(null());
            let class = wide("PolestarPlusOverlay");
            let mut definition: WNDCLASSW = zeroed();
            definition.lpfnWndProc = Some(procedure);
            definition.hInstance = instance;
            definition.lpszClassName = class.as_ptr();
            if RegisterClassW(&definition) == 0 {
                bail!("cannot register the overlay's window class");
            }
            // Layered: drawn with its own transparency. Transparent: the mouse
            // goes through it. No-activate: it never takes the keyboard.
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                class.as_ptr(),
                wide("Polestar Plus").as_ptr(),
                WS_POPUP,
                0,
                0,
                1,
                1,
                null_mut(),
                null_mut(),
                instance,
                null(),
            );
            if hwnd.is_null() {
                bail!("cannot create the overlay window");
            }
            Ok(Panel { hwnd, surface: None, visible: false })
        }
    }

    /// Puts `pixmap` on screen at `at`, faded to `opacity`.
    fn show(&mut self, pixmap: &Pixmap, at: (i32, i32), opacity: u8) -> Result<()> {
        let (width, height) = (pixmap.width() as i32, pixmap.height() as i32);
        unsafe {
            let screen = GetDC(null_mut());
            if self.surface.as_ref().map_or(true, |s| (s.width, s.height) != (width, height)) {
                self.surface = Some(Surface::new(screen, width, height)?);
            }
            let surface = self.surface.as_mut().unwrap();
            // tiny-skia holds premultiplied RGBA, the window wants premultiplied BGRA.
            for (out, pixel) in surface.pixels().chunks_exact_mut(4).zip(pixmap.data().chunks_exact(4)) {
                out.copy_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
            }
            let position = POINT { x: at.0, y: at.1 };
            let size = SIZE { cx: width, cy: height };
            let origin = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: opacity,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            let ok = UpdateLayeredWindow(self.hwnd, screen, &position, &size, surface.dc, &origin, 0, &blend, ULW_ALPHA);
            ReleaseDC(null_mut(), screen);
            if ok == 0 {
                bail!("the overlay window would not take its picture");
            }
            if !self.visible {
                ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                self.visible = true;
            }
            // Other topmost windows may have come up since; stay above the game.
            SetWindowPos(self.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        Ok(())
    }

    fn hide(&mut self) {
        if self.visible {
            unsafe { ShowWindow(self.hwnd, SW_HIDE) };
            self.visible = false;
        }
    }

    /// Lets Windows deliver what it has for the window; false once it is told to quit.
    fn pump(&mut self) -> bool {
        unsafe {
            let mut message: MSG = zeroed();
            while PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) != 0 {
                if message.message == WM_QUIT {
                    return false;
                }
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        true
    }
}

impl Drop for Panel {
    fn drop(&mut self) {
        unsafe { DestroyWindow(self.hwnd) };
    }
}

/// What is on the panel right now, to tell when it needs drawing again.
#[derive(PartialEq)]
enum Shown {
    Live(Snapshot),
    Waiting(String),
}

fn save(pixmap: &Pixmap, path: &std::path::Path) -> Result<()> {
    pixmap.save_png(path).with_context(|| format!("cannot write {}", path.display()))
}

pub fn run(o: &Options) -> Result<()> {
    let mut source = Source::new(&o.title, o.capture)?;
    let mut fonts = Fonts::load()?;

    if let Some(path) = &o.png {
        let scale = o.scale.unwrap_or_else(|| source.window().map_or(1.0, |window| scale_for(&window)));
        let deadline = Instant::now() + Duration::from_secs(5);
        let pixmap = loop {
            match source.poll() {
                Ok(frame) => break hud::draw(&View::Live(&model::parse(&frame.payload)), &mut fonts, scale),
                Err(miss) if Instant::now() >= deadline => break hud::draw(&View::Waiting(&miss.brief()), &mut fonts, scale),
                Err(_) => std::thread::sleep(o.interval),
            }
        };
        save(&pixmap, path)?;
        println!("Drew the panel ({}x{} px) into {}", pixmap.width(), pixmap.height(), path.display());
        return Ok(());
    }

    let mut panel = Panel::new()?;
    println!("Overlay running over \"{}\". Clicks go through it; Ctrl+C here closes it.", o.title);
    if !o.always {
        println!("It shows while the game is the active window (--always keeps it up).");
    }

    let mut drawn: Option<(Shown, u32, Pixmap)> = None;
    let mut placed: Option<((i32, i32), u8)> = None;
    let mut good: Option<Snapshot> = None;
    let (mut seq, mut beat, mut hit) = (None, Instant::now(), Instant::now() - PATIENCE);
    let mut next = Instant::now();
    while panel.pump() {
        if Instant::now() < next {
            std::thread::sleep(Duration::from_millis(5));
            continue;
        }
        next = Instant::now() + o.interval;

        // No game window, or the player is in another one: nothing to float
        // over, and nothing worth reading until they are back.
        let window = match source.window() {
            Ok(window) if o.always || source.focused() => window,
            _ => {
                panel.hide();
                placed = None;
                next = Instant::now() + Duration::from_millis(250);
                continue;
            }
        };

        let shown = match source.poll() {
            Ok(frame) => {
                if seq != Some(frame.seq) {
                    seq = Some(frame.seq);
                    beat = Instant::now();
                }
                hit = Instant::now();
                let snapshot = model::parse(&frame.payload);
                good = Some(snapshot.clone());
                Shown::Live(snapshot)
            }
            Err(miss) => match &good {
                Some(snapshot) if hit.elapsed() < PATIENCE => Shown::Live(snapshot.clone()),
                _ => Shown::Waiting(miss.brief()),
            },
        };

        let scale = o.scale.unwrap_or_else(|| scale_for(&window));
        let fresh = drawn.as_ref().map_or(true, |(was, at_scale, _)| *was != shown || *at_scale != scale.to_bits());
        if fresh {
            let pixmap = match &shown {
                Shown::Live(snapshot) => hud::draw(&View::Live(snapshot), &mut fonts, scale),
                Shown::Waiting(why) => hud::draw(&View::Waiting(why), &mut fonts, scale),
            };
            drawn = Some((shown, scale.to_bits(), pixmap));
        }
        let (shown, _, pixmap) = drawn.as_ref().unwrap();

        // A strip that has stopped changing is a paused game: fade the panel.
        let stale = matches!(shown, Shown::Live(_)) && beat.elapsed() > STALE;
        let opacity = if stale { 110 } else { 255 };
        let size = (pixmap.width() as i32, pixmap.height() as i32);
        let offset = o.offset.unwrap_or_else(|| beside_centre(o.anchor, scale, size));
        let at = place(o.anchor, offset, scale, &window, size);
        if fresh || placed != Some((at, opacity)) {
            panel.show(pixmap, at, opacity)?;
            placed = Some((at, opacity));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window() -> WindowInfo {
        WindowInfo { title: "World of Warcraft".into(), client: (3440, 1440), origin: (100, 50) }
    }

    #[test]
    fn anchors_place_the_panel_inside_the_game() {
        let (w, panel) = (window(), (400, 200));
        assert_eq!(scale_for(&w), 1440.0 / 1080.0);
        // Margin 56 at scale 1.
        assert_eq!(place(Anchor::Top, (0, 0), 1.0, &w, panel), (100 + 1520, 50 + 56));
        assert_eq!(place(Anchor::TopLeft, (0, 0), 1.0, &w, panel), (156, 106));
        assert_eq!(place(Anchor::BottomRight, (0, 0), 1.0, &w, panel), (100 + 3440 - 400 - 56, 50 + 1440 - 200 - 56));
        assert_eq!(place(Anchor::Center, (10, -20), 1.0, &w, panel), (100 + 1520 + 10, 50 + 620 - 20));
        assert_eq!(place(Anchor::Left, (0, 0), 2.0, &w, panel), (100 + 112, 50 + 620));
    }

    #[test]
    fn the_panel_never_covers_the_strip() {
        let at = place(Anchor::TopLeft, (-56, -500), 1.0, &window(), (400, 200));
        assert_eq!(at, (100, 50 + STRIP_CLEARANCE));
    }

    #[test]
    fn at_the_top_the_panel_leaves_the_centre_to_polestars_arrow() {
        let (w, panel) = (window(), (400, 200));
        let offset = beside_centre(Anchor::Top, 1.0, panel);
        let (x, _) = place(Anchor::Top, offset, 1.0, &w, panel);
        assert_eq!(x - w.origin.0, 3440 / 2 + 150, "its left edge is 150 px right of the middle");
        assert_eq!(beside_centre(Anchor::Left, 1.0, panel), (0, 0));
    }

    #[test]
    fn anchor_names() {
        assert_eq!(Anchor::named("top"), Some(Anchor::Top));
        assert_eq!(Anchor::named("centre"), Some(Anchor::Center));
        assert_eq!(Anchor::named("bottom-left"), Some(Anchor::BottomLeft));
        assert_eq!(Anchor::named("middle"), None);
        assert_eq!(Anchor::BottomRight.cell(), (2, 2));
        assert_eq!(Anchor::Left.cell(), (0, 1));
    }
}
