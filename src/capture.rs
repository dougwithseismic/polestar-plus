//! Grabs the top-left corner of the game window's picture. Nothing here opens
//! or touches the game's process: `Screen` copies pixels from the desktop,
//! `Window` asks the window manager for the window's own picture (which also
//! works while another window covers the game).

use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::ptr::null_mut;

use anyhow::{anyhow, bail, Result};
use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, ClientToScreen, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush, GetDC, ReleaseDC,
    SelectObject, BITMAPINFO, BITMAPINFOHEADER, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ, SRCCOPY,
};
use windows_sys::Win32::Storage::Xps::PrintWindow;
use windows_sys::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClientRect, GetForegroundWindow, GetWindowTextW, IsIconic, IsWindow, IsWindowVisible,
};

use crate::protocol::Image;

/// Enough of the top edge for the strip (750 x 6 px as shipped) at twice its size.
const REGION: (i32, i32) = (1600, 64);
const PW_CLIENTONLY: u32 = 1;
const PW_RENDERFULLCONTENT: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Screen,
    Window,
}

impl Mode {
    pub fn name(self) -> &'static str {
        match self {
            Mode::Screen => "screen",
            Mode::Window => "window",
        }
    }
}

#[derive(Debug, Clone)]
pub struct WindowInfo {
    pub title: String,
    pub client: (i32, i32),
    pub origin: (i32, i32),
}

/// A memory bitmap GDI can draw into and we can read and write: top-down
/// BGRA, `width * 4` bytes a row.
pub struct Surface {
    pub dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
    bits: *mut u8,
    pub width: i32,
    pub height: i32,
}

impl Surface {
    pub fn new(like: HDC, width: i32, height: i32) -> Result<Self> {
        unsafe {
            let dc = CreateCompatibleDC(like);
            if dc.is_null() {
                bail!("CreateCompatibleDC failed");
            }
            let mut info: BITMAPINFO = zeroed();
            info.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
            info.bmiHeader.biWidth = width;
            info.bmiHeader.biHeight = -height; // top-down
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            let mut bits: *mut c_void = null_mut();
            let bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
            if bitmap.is_null() || bits.is_null() {
                DeleteDC(dc);
                bail!("CreateDIBSection failed for {width}x{height}");
            }
            let previous = SelectObject(dc, bitmap);
            Ok(Surface { dc, bitmap, previous, bits: bits as *mut u8, width, height })
        }
    }

    /// The whole bitmap's bytes, to draw into.
    pub fn pixels(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.bits, self.width as usize * self.height as usize * 4) }
    }

    /// The top-left `width` x `height` pixels.
    fn corner(&self, width: i32, height: i32) -> Image {
        let (width, height) = (width.min(self.width) as usize, height.min(self.height) as usize);
        let stride = self.width as usize * 4;
        let mut image = Image::new(width, height);
        unsafe {
            GdiFlush();
            for row in 0..height {
                let source = std::slice::from_raw_parts(self.bits.add(row * stride), width * 4);
                image.bgra[row * width * 4..(row + 1) * width * 4].copy_from_slice(source);
            }
        }
        image
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.previous);
            DeleteObject(self.bitmap);
            DeleteDC(self.dc);
        }
    }
}

struct Search {
    wanted: String,
    found: Option<(HWND, String)>,
}

unsafe extern "system" fn visit(hwnd: HWND, param: LPARAM) -> BOOL {
    let search = &mut *(param as *mut Search);
    if IsWindowVisible(hwnd) == 0 {
        return 1;
    }
    let mut buffer = [0u16; 256];
    let len = GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32);
    let title = String::from_utf16_lossy(&buffer[..len.max(0) as usize]);
    if title == search.wanted {
        search.found = Some((hwnd, title));
        return 0;
    }
    1
}

pub struct Capturer {
    title: String,
    hwnd: HWND,
    screen_dc: HDC,
    region: Surface,
    full: Option<Surface>,
}

impl Capturer {
    /// `title` is the game window's exact title.
    pub fn new(title: &str) -> Result<Self> {
        unsafe {
            // Without this a scaled display hands back stretched coordinates.
            SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            let screen_dc = GetDC(null_mut());
            if screen_dc.is_null() {
                bail!("cannot open the screen for reading");
            }
            let region = Surface::new(screen_dc, REGION.0, REGION.1)?;
            Ok(Capturer { title: title.to_string(), hwnd: null_mut(), screen_dc, region, full: None })
        }
    }

    fn window(&mut self) -> Result<HWND> {
        unsafe {
            if !self.hwnd.is_null() && IsWindow(self.hwnd) != 0 {
                return Ok(self.hwnd);
            }
            let mut search = Search { wanted: self.title.clone(), found: None };
            EnumWindows(Some(visit), &mut search as *mut Search as LPARAM);
            let (hwnd, _) = search.found.ok_or_else(|| anyhow!("no window titled \"{}\" (is the game running?)", self.title))?;
            self.hwnd = hwnd;
            self.full = None;
            Ok(hwnd)
        }
    }

    pub fn info(&mut self) -> Result<WindowInfo> {
        let hwnd = self.window()?;
        unsafe {
            if IsIconic(hwnd) != 0 {
                bail!("the game window is minimised");
            }
            let mut rect: RECT = zeroed();
            let mut origin = POINT { x: 0, y: 0 };
            if GetClientRect(hwnd, &mut rect) == 0 || ClientToScreen(hwnd, &mut origin) == 0 {
                bail!("cannot measure the game window");
            }
            let client = (rect.right - rect.left, rect.bottom - rect.top);
            if client.0 <= 0 || client.1 <= 0 {
                bail!("the game window has no visible area");
            }
            Ok(WindowInfo { title: self.title.clone(), client, origin: (origin.x, origin.y) })
        }
    }

    /// The game is the window the player is typing into.
    pub fn focused(&mut self) -> bool {
        self.window().is_ok_and(|hwnd| unsafe { GetForegroundWindow() } == hwnd)
    }

    /// The top-left corner of the game's picture.
    pub fn grab(&mut self, mode: Mode) -> Result<Image> {
        let info = self.info()?;
        let (width, height) = (info.client.0.min(REGION.0), info.client.1.min(REGION.1));
        unsafe {
            match mode {
                Mode::Screen => {
                    if BitBlt(self.region.dc, 0, 0, width, height, self.screen_dc, info.origin.0, info.origin.1, SRCCOPY) == 0 {
                        bail!("copying from the screen failed");
                    }
                    Ok(self.region.corner(width, height))
                }
                Mode::Window => {
                    let stale = self.full.as_ref().map_or(true, |s| (s.width, s.height) != info.client);
                    if stale {
                        self.full = Some(Surface::new(self.screen_dc, info.client.0, info.client.1)?);
                    }
                    let full = self.full.as_ref().unwrap();
                    if PrintWindow(self.hwnd, full.dc, PW_CLIENTONLY | PW_RENDERFULLCONTENT) == 0 {
                        bail!("the window manager would not hand over the window's picture");
                    }
                    Ok(full.corner(width, height))
                }
            }
        }
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe {
            ReleaseDC(null_mut(), self.screen_dc);
        }
    }
}
