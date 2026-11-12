//! polestar-plus: reads the Polestar add-on's guide and arrow out of World of
//! Warcraft: Forever, through the strip the PolestarLink add-on paints in the
//! game window's corner.

mod capture;
mod hud;
mod model;
mod overlay;
mod protocol;
mod render;
mod route;
mod source;
mod text;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};

use capture::{Capturer, Mode};
use overlay::Anchor;
use protocol::{decode, Frame, Image};
use source::{Source, PATIENCE};

const DEFAULT_TITLE: &str = "World of Warcraft";
const DEFAULT_WOW: &str = r"C:\Program Files (x86)\World of Warcraft\_forever_";
/// The add-ons this program carries, each a folder and its files:
/// PolestarLink paints the strip this program reads; PolestarNext shows the
/// next ability inside the game and has nothing to do with the strip.
const ADDONS: [(&str, &[(&str, &str)]); 2] = [
    (
        "PolestarLink",
        &[
            ("PolestarLink.toc", include_str!("../addon/PolestarLink/PolestarLink.toc")),
            ("PolestarLink.lua", include_str!("../addon/PolestarLink/PolestarLink.lua")),
        ],
    ),
    (
        "PolestarNext",
        &[
            ("PolestarNext.toc", include_str!("../addon/PolestarNext/PolestarNext.toc")),
            ("Core.lua", include_str!("../addon/PolestarNext/Core.lua")),
            ("Scan.lua", include_str!("../addon/PolestarNext/Scan.lua")),
            ("Rules.lua", include_str!("../addon/PolestarNext/Rules.lua")),
            ("Numbers.lua", include_str!("../addon/PolestarNext/Numbers.lua")),
            ("Classes.lua", include_str!("../addon/PolestarNext/Classes.lua")),
            ("Engine.lua", include_str!("../addon/PolestarNext/Engine.lua")),
            ("Edit.lua", include_str!("../addon/PolestarNext/Edit.lua")),
            ("Display.lua", include_str!("../addon/PolestarNext/Display.lua")),
        ],
    ),
];

/// The add-on publishes ten times a second; quieter than this and it has stopped.
const STALE: Duration = Duration::from_secs(2);

const USAGE: &str = "\
polestar-plus: Polestar's guide, quest and arrow, read live from the game window

  polestar-plus [watch]     live view in this terminal (the default)
  polestar-plus once        print the current state once
  polestar-plus json        one JSON object a line, each time something changes
  polestar-plus overlay     a click-through panel over the game: arrow, distance, quest, goals
  polestar-plus doctor      check the window, the capture and the add-on; saves what it sees as PNG
  polestar-plus install     copy the PolestarLink and PolestarNext add-ons into the game
  polestar-plus decode <png>  read the strip out of a saved picture (one of doctor's)

Options
  --once              with json: print one object and stop
  --json              with decode: print JSON instead of the view
  --anchor <where>    with overlay: top (default), top-left, top-right, left, right, center,
                      bottom, bottom-left or bottom-right of the game window
  --offset <x,y>      with overlay: pixels to move it from there (right and down are positive).
                      Without it the top anchor sits just right of centre, beside Polestar's own
                      arrow; --offset 0,0 puts it dead centre
  --scale <n>         with overlay: size, 1 is made for a 1080-line window (default: fits the window)
  --always            with overlay: keep it up while another window is active
  --png <file>        with overlay or decode: draw the panel once into a PNG and stop
  --interval <ms>     how often to look at the window (default 100)
  --capture <how>     screen, window or auto (default auto). screen copies from the desktop and
                      needs the game's corner uncovered; window asks Windows for the game's own
                      picture and works while it is covered
  --title <text>      the game window's title (default \"World of Warcraft\")
  --wow <dir>         the game folder (default C:\\Program Files (x86)\\World of Warcraft\\_forever_)
";

struct Options {
    command: String,
    once: bool,
    as_json: bool,
    file: Option<PathBuf>,
    interval: Duration,
    capture: Option<Mode>,
    title: String,
    wow: PathBuf,
    anchor: Anchor,
    offset: Option<(i32, i32)>,
    scale: Option<f32>,
    always: bool,
    png: Option<PathBuf>,
}

fn options() -> Result<Options> {
    let mut o = Options {
        command: "watch".to_string(),
        once: false,
        as_json: false,
        file: None,
        interval: Duration::from_millis(100),
        capture: None,
        title: DEFAULT_TITLE.to_string(),
        wow: PathBuf::from(DEFAULT_WOW),
        anchor: Anchor::Top,
        offset: None,
        scale: None,
        always: false,
        png: None,
    };
    let mut args = std::env::args().skip(1);
    let mut named = false;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| anyhow!("{name} needs a value"));
        match arg.as_str() {
            "--once" => o.once = true,
            "--json" => o.as_json = true,
            "--interval" => {
                let ms: u64 = value("--interval")?.parse().context("--interval takes milliseconds")?;
                o.interval = Duration::from_millis(ms.clamp(10, 10_000));
            }
            "--capture" => {
                o.capture = match value("--capture")?.as_str() {
                    "screen" => Some(Mode::Screen),
                    "window" => Some(Mode::Window),
                    "auto" => None,
                    other => bail!("--capture takes screen, window or auto, not \"{other}\""),
                }
            }
            "--title" => o.title = value("--title")?,
            "--anchor" => {
                let name = value("--anchor")?;
                o.anchor = Anchor::named(&name).ok_or_else(|| anyhow!("--anchor does not know \"{name}\""))?;
            }
            "--offset" => {
                let text = value("--offset")?;
                let parsed = text.split_once(',').and_then(|(x, y)| Some((x.trim().parse().ok()?, y.trim().parse().ok()?)));
                o.offset = Some(parsed.ok_or_else(|| anyhow!("--offset takes two whole numbers, like 0,40"))?);
            }
            "--scale" => {
                let scale: f32 = value("--scale")?.parse().context("--scale takes a number")?;
                o.scale = Some(scale.clamp(0.5, 4.0));
            }
            "--always" => o.always = true,
            "--png" => o.png = Some(PathBuf::from(value("--png")?)),
            "--wow" => o.wow = PathBuf::from(value("--wow")?),
            "-h" | "--help" | "help" => o.command = "help".to_string(),
            command if !command.starts_with('-') && !named => {
                o.command = command.to_string();
                named = true;
            }
            file if !file.starts_with('-') && o.command == "decode" && o.file.is_none() => o.file = Some(PathBuf::from(file)),
            other => bail!("unknown argument \"{other}\"\n\n{USAGE}"),
        }
    }
    Ok(o)
}

/// True when standard output is a console; ANSI escapes are switched on for it.
fn console() -> bool {
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, SetConsoleMode, ENABLE_VIRTUAL_TERMINAL_PROCESSING, STD_OUTPUT_HANDLE,
    };
    unsafe {
        let handle = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut mode = 0;
        if GetConsoleMode(handle, &mut mode) == 0 {
            return false;
        }
        SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0
    }
}

fn watch(o: &Options) -> Result<()> {
    let mut source = Source::new(&o.title, o.capture)?;
    let in_place = console();
    let mut out = std::io::stdout().lock();
    if in_place {
        write!(out, "\x1b[2J")?;
    }
    let mut shown: Vec<String> = Vec::new();
    let mut good: Vec<String> = Vec::new();
    let (mut seq, mut beat, mut hit) = (None, Instant::now(), Instant::now() - PATIENCE);
    loop {
        let lines = match source.poll() {
            Ok(frame) => {
                if seq != Some(frame.seq) {
                    seq = Some(frame.seq);
                    beat = Instant::now();
                }
                hit = Instant::now();
                good = render::dashboard(&model::parse(&frame.payload));
                let mut lines = good.clone();
                if beat.elapsed() > STALE {
                    lines.push(String::new());
                    lines.push("(the strip has stopped changing: is the game on a loading screen?)".to_string());
                }
                lines
            }
            Err(_) if hit.elapsed() < PATIENCE && !good.is_empty() => good.clone(),
            Err(miss) => miss.lines(),
        };
        if lines != shown {
            if in_place {
                write!(out, "\x1b[H")?;
                for line in &lines {
                    write!(out, "{line}\x1b[K\r\n")?;
                }
                write!(out, "\x1b[J")?;
            } else {
                for line in &lines {
                    writeln!(out, "{line}")?;
                }
                writeln!(out)?;
            }
            out.flush()?;
            shown = lines;
        }
        std::thread::sleep(o.interval);
    }
}

/// The first good frame, or why there was none within a few seconds.
fn first_frame(source: &mut Source, interval: Duration) -> Result<Frame> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match source.poll() {
            Ok(frame) => return Ok(frame),
            Err(miss) if Instant::now() >= deadline => bail!("{}", miss.lines().join("\n")),
            Err(_) => std::thread::sleep(interval),
        }
    }
}

fn once(o: &Options) -> Result<()> {
    let mut source = Source::new(&o.title, o.capture)?;
    let frame = first_frame(&mut source, o.interval)?;
    for line in render::dashboard(&model::parse(&frame.payload)) {
        println!("{line}");
    }
    Ok(())
}

fn json(o: &Options) -> Result<()> {
    let mut source = Source::new(&o.title, o.capture)?;
    let mut out = std::io::stdout().lock();
    let mut last = first_frame(&mut source, o.interval)?.payload;
    loop {
        writeln!(out, "{}", serde_json::to_string(&model::parse(&last))?)?;
        out.flush()?;
        if o.once {
            return Ok(());
        }
        last = loop {
            std::thread::sleep(o.interval);
            match source.poll() {
                Ok(frame) if frame.payload != last => break frame.payload,
                _ => {}
            }
        };
    }
}

fn save_png(image: &Image, path: &Path) -> Result<()> {
    let file = std::fs::File::create(path).with_context(|| format!("cannot write {}", path.display()))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), image.width as u32, image.height as u32);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    let rgb: Vec<u8> = image.bgra.chunks_exact(4).flat_map(|p| [p[2], p[1], p[0]]).collect();
    encoder.write_header()?.write_image_data(&rgb)?;
    Ok(())
}

fn load_png(path: &Path) -> Result<Image> {
    let file = std::fs::File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    let mut reader = png::Decoder::new(file).read_info()?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buffer)?;
    let channels = match (info.color_type, info.bit_depth) {
        (png::ColorType::Rgb, png::BitDepth::Eight) => 3,
        (png::ColorType::Rgba, png::BitDepth::Eight) => 4,
        other => bail!("{} is {:?}; an 8-bit RGB or RGBA PNG is needed", path.display(), other),
    };
    let mut image = Image::new(info.width as usize, info.height as usize);
    for (pixel, out) in buffer[..info.buffer_size()].chunks_exact(channels).zip(image.bgra.chunks_exact_mut(4)) {
        out.copy_from_slice(&[pixel[2], pixel[1], pixel[0], 0xFF]);
    }
    Ok(image)
}

fn decode_file(o: &Options) -> Result<()> {
    let path = o.file.as_ref().ok_or_else(|| anyhow!("decode needs a PNG file"))?;
    let frame = decode(&load_png(path)?, None).map_err(|why| anyhow!("{}: {why}", path.display()))?;
    let snapshot = model::parse(&frame.payload);
    if let Some(out) = &o.png {
        let pixmap = hud::draw(&hud::View::Live(&snapshot), &mut text::Fonts::load()?, o.scale.unwrap_or(1.0));
        pixmap.save_png(out).with_context(|| format!("cannot write {}", out.display()))?;
        println!("Drew the panel ({}x{} px) into {}", pixmap.width(), pixmap.height(), out.display());
    } else if o.as_json {
        println!("{}", serde_json::to_string_pretty(&snapshot)?);
    } else {
        for line in render::dashboard(&snapshot) {
            println!("{line}");
        }
    }
    Ok(())
}

fn doctor(o: &Options) -> Result<()> {
    for (addon, files) in ADDONS {
        let installed = o.wow.join("Interface").join("AddOns").join(addon);
        let current = files.iter().all(|(name, text)| std::fs::read_to_string(installed.join(name)).is_ok_and(|on_disk| on_disk == *text));
        println!(
            "Add-on   {addon}: {} in {}",
            if current {
                "installed and current"
            } else if installed.exists() {
                "installed but not this version (polestar-plus install, then /reload)"
            } else {
                "not installed (polestar-plus install, then restart the game)"
            },
            installed.display()
        );
    }

    let mut capturer = Capturer::new(&o.title)?;
    let info = capturer.info()?;
    println!(
        "Window   \"{}\", picture {}x{} px at {},{} on the desktop",
        info.title, info.client.0, info.client.1, info.origin.0, info.origin.1
    );

    for mode in [Mode::Screen, Mode::Window] {
        let image = match capturer.grab(mode) {
            Ok(image) => image,
            Err(why) => {
                println!("{:<8} capture failed: {why}", mode.name());
                continue;
            }
        };
        let path = PathBuf::from(format!("polestar-plus-{}.png", mode.name()));
        save_png(&image, &path)?;
        let black = image.bgra.chunks_exact(4).all(|p| p[0] == 0 && p[1] == 0 && p[2] == 0);
        match decode(&image, None) {
            Ok(frame) => {
                let snapshot = model::parse(&frame.payload);
                println!(
                    "{:<8} strip read: {}x{} cells of {} px, {} bytes, add-on says \"{}\"  ({})",
                    mode.name(), frame.cols, frame.rows, frame.grid.pitch, frame.payload.len(), snapshot.status, path.display()
                );
            }
            Err(why) => println!(
                "{:<8} {}{}  ({})",
                mode.name(),
                why,
                if black { "; the whole capture is black, so this way of capturing does not see the game" } else { "" },
                path.display()
            ),
        }
    }
    Ok(())
}

fn install(o: &Options) -> Result<()> {
    let addons = o.wow.join("Interface").join("AddOns");
    if !addons.is_dir() {
        bail!("{} is not there; pass the game folder with --wow", addons.display());
    }
    let mut new_folder = false;
    for (addon, files) in ADDONS {
        let folder = addons.join(addon);
        // A folder the game has not seen, or a file it has not loaded before,
        // needs a full restart; changed files only need a /reload.
        new_folder |= files.iter().any(|(name, _)| !folder.join(name).is_file());
        std::fs::create_dir_all(&folder).with_context(|| format!("cannot create {}", folder.display()))?;
        for (name, text) in files.iter() {
            std::fs::write(folder.join(name), text).with_context(|| format!("cannot write {name} in {}", folder.display()))?;
        }
        println!("Installed {addon} in {}", folder.display());
    }
    if new_folder {
        println!("Quit the game completely and start it again: a /reload does not pick up a new add-on folder.");
    } else {
        println!("Type /reload in the game to load the new versions.");
    }
    Ok(())
}

fn main() -> ExitCode {
    let result = options().and_then(|o| match o.command.as_str() {
        "watch" => watch(&o),
        "once" => once(&o),
        "json" => json(&o),
        "overlay" => overlay::run(&o),
        "doctor" => doctor(&o),
        "install" => install(&o),
        "decode" => decode_file(&o),
        "help" => {
            print!("{USAGE}");
            Ok(())
        }
        other => bail!("unknown command \"{other}\"\n\n{USAGE}"),
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            eprintln!("{why:#}");
            ExitCode::FAILURE
        }
    }
}
