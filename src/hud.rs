//! The overlay's panel, drawn from a snapshot into a transparent pixmap:
//! a dial with Polestar's arrow, the distance, then the quest and its goals.

use tiny_skia::{FillRule, Paint, Path, PathBuilder, Pixmap, PixmapPaint, Stroke, Transform};

use crate::model::{Goal, Snapshot};
use crate::route::{self, Preview};
use crate::text::{Colour, Fonts, Weight};

/// What the panel shows.
pub enum View<'a> {
    Live(&'a Snapshot),
    /// No strip to read: one line saying why.
    Waiting(&'a str),
}

const WIDTH: f32 = 372.0;
const PAD: f32 = 14.0;
const DIAL: f32 = 58.0;
const MAX_GOALS: usize = 5;
/// The route view's height, and the yards of path it can show ahead.
const ROUTE: f32 = 104.0;
const RANGES: [f64; 6] = [40.0, 60.0, 90.0, 130.0, 180.0, 250.0];

const PANEL: Colour = [14, 16, 22, 204];
const EDGE: Colour = [255, 255, 255, 30];
const BRIGHT: Colour = [255, 255, 255, 240];
const SOFT: Colour = [255, 255, 255, 178];
const DIM: Colour = [255, 255, 255, 120];
const GOLD: Colour = [244, 196, 84, 255];
const GREEN: Colour = [124, 214, 142, 255];
const RED: Colour = [255, 132, 110, 255];

fn paint(colour: Colour) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color_rgba8(colour[0], colour[1], colour[2], colour[3]);
    paint.anti_alias = true;
    paint
}

fn fill(pixmap: &mut Pixmap, path: &Path, colour: Colour) {
    pixmap.fill_path(path, &paint(colour), FillRule::Winding, Transform::identity(), None);
}

fn stroke(pixmap: &mut Pixmap, path: &Path, colour: Colour, width: f32) {
    let stroke = Stroke { width, line_cap: tiny_skia::LineCap::Round, line_join: tiny_skia::LineJoin::Round, ..Stroke::default() };
    pixmap.stroke_path(path, &paint(colour), &stroke, Transform::identity(), None);
}

fn rounded(x: f32, y: f32, w: f32, h: f32, r: f32) -> Path {
    let k = r * 0.5523;
    let mut p = PathBuilder::new();
    p.move_to(x + r, y);
    p.line_to(x + w - r, y);
    p.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    p.line_to(x + w, y + h - r);
    p.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    p.line_to(x + r, y + h);
    p.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    p.line_to(x, y + r);
    p.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    p.close();
    p.finish().expect("a rounded rectangle is a path")
}

fn polygon(points: &[(f32, f32)]) -> Path {
    let mut p = PathBuilder::new();
    p.move_to(points[0].0, points[0].1);
    for point in &points[1..] {
        p.line_to(point.0, point.1);
    }
    p.close();
    p.finish().expect("a polygon is a path")
}

fn line(from: (f32, f32), to: (f32, f32)) -> Path {
    let mut p = PathBuilder::new();
    p.move_to(from.0, from.1);
    p.line_to(to.0, to.1);
    p.finish().expect("a line is a path")
}

fn circle(cx: f32, cy: f32, r: f32) -> Path {
    PathBuilder::from_circle(cx, cy, r).expect("a circle is a path")
}

/// What the big line and the line under it say for the arrow's state.
fn headline(s: &Snapshot) -> (String, String) {
    let nav = &s.nav;
    let yards = nav.distance_yd.map(|d| format!("{d:.0} yd"));
    let mut parts: Vec<String> = Vec::new();
    if let Some(turn) = nav.turn_deg {
        let size = turn.abs().round();
        parts.push(if size < 3.0 {
            "straight ahead".to_string()
        } else if size > 177.0 {
            "behind you".to_string()
        } else {
            format!("{} {size:.0}°", if turn > 0.0 { "right" } else { "left" })
        });
    }
    if let (Some(deg), Some(point)) = (nav.bearing_deg, nav.bearing) {
        parts.push(format!("{point} {deg:03.0}°"));
    }
    if nav.along_path {
        parts.push("by path".to_string());
    }
    if let Some(floor) = &nav.floor {
        parts.push(format!("go {floor} a floor"));
    }
    let detail = parts.join("  ·  ");
    match nav.state.as_str() {
        "travel" => (yards.unwrap_or_else(|| "On the way".to_string()), detail),
        "arrived" => ("Arrived".to_string(), detail),
        "search" => ("Look around here".to_string(), detail),
        "instruction" => (yards.unwrap_or_else(|| "Travel step".to_string()), "follow Polestar's travel step".to_string()),
        "far" => ("Another continent".to_string(), String::new()),
        "taxi" => ("On a flight".to_string(), String::new()),
        "instance" => ("In an instance".to_string(), String::new()),
        "nopos" => ("No position here".to_string(), String::new()),
        "unknown" => ("Target not resolved".to_string(), String::new()),
        _ => ("No target".to_string(), String::new()),
    }
}

/// The dial: a ring with a tick for "ahead", and the arrow turned to where
/// Polestar points, or a dot when it points nowhere.
fn dial(pixmap: &mut Pixmap, s: &Snapshot, cx: f32, cy: f32, r: f32, k: f32) {
    stroke(pixmap, &circle(cx, cy, r), [255, 255, 255, 46], 1.5 * k);
    stroke(pixmap, &line((cx, cy - r - 1.0 * k), (cx, cy - r + 5.0 * k)), [255, 255, 255, 150], 1.5 * k);
    let here = matches!(s.nav.state.as_str(), "arrived" | "search");
    let colour = if here { GREEN } else { GOLD };
    match s.nav.turn_deg.filter(|_| matches!(s.nav.state.as_str(), "travel" | "arrived" | "search" | "instruction")) {
        Some(turn) => {
            let (sin, cos) = (turn as f32).to_radians().sin_cos();
            let size = r * 0.74;
            // Up is ahead; y grows downwards, so a positive turn swings right.
            let shape = [(0.0, -1.0), (0.66, 0.80), (0.0, 0.40), (-0.66, 0.80)];
            let points: Vec<(f32, f32)> =
                shape.iter().map(|(x, y)| (cx + (x * cos - y * sin) * size, cy + (x * sin + y * cos) * size)).collect();
            fill(pixmap, &polygon(&points), colour);
        }
        None => fill(pixmap, &circle(cx, cy, 4.0 * k), DIM),
    }
}

/// A goal's mark: a pointer for the one the arrow leads to, else a dot.
fn mark(pixmap: &mut Pixmap, goal: &Goal, x: f32, y: f32, k: f32) {
    if goal.current {
        fill(pixmap, &polygon(&[(x, y - 4.5 * k), (x + 7.0 * k, y), (x, y + 4.5 * k)]), GOLD);
    } else {
        fill(pixmap, &circle(x + 3.0 * k, y, 2.2 * k), DIM);
    }
}

/// The route view: the path ahead as a line running up from the player's
/// mark at the bottom, with the way the character faces pointing up. Returns
/// how many yards the view reaches.
fn route_view(preview: &Preview, width: f32, height: f32, k: f32) -> (Pixmap, f64) {
    let mut view = Pixmap::new(width as u32, height as u32).expect("the route view has a size");
    fill(&mut view, &rounded(0.0, 0.0, width, height, 7.0 * k), [255, 255, 255, 16]);
    // The shortest range that holds what is left, so a short path is not a dot.
    let range = RANGES.iter().copied().find(|r| *r >= preview.remaining).unwrap_or(RANGES[RANGES.len() - 1]);
    // A little room below the player, for a path that starts off sideways.
    let (ox, oy) = (width / 2.0, height - 22.0 * k);
    let per_yard = (height - 38.0 * k) / range as f32;
    let at = |p: &(f64, f64)| (ox + p.0 as f32 * per_yard, oy - p.1 as f32 * per_yard);

    let mut path = PathBuilder::new();
    path.move_to(ox, oy);
    for point in &preview.points {
        let (x, y) = at(point);
        path.line_to(x, y);
    }
    if let Some(path) = path.finish() {
        stroke(&mut view, &path, [0, 0, 0, 90], 5.5 * k);
        stroke(&mut view, &path, GOLD, 3.0 * k);
    }
    // The path's end, when the view reaches it.
    if let Some(end) = preview.points.last() {
        let (x, y) = at(end);
        if x > 0.0 && x < width && y > 0.0 && y < height {
            fill(&mut view, &circle(x, y, 5.0 * k), GREEN);
            fill(&mut view, &circle(x, y, 2.0 * k), [14, 16, 22, 255]);
        }
    }
    // The player: a mark pointing the way they face, or a dot when north is up.
    if preview.heading_up {
        fill(&mut view, &polygon(&[(ox, oy - 8.0 * k), (ox + 6.0 * k, oy + 6.0 * k), (ox, oy + 2.5 * k), (ox - 6.0 * k, oy + 6.0 * k)]), BRIGHT);
    } else {
        fill(&mut view, &circle(ox, oy, 4.0 * k), BRIGHT);
    }
    (view, range)
}

struct GoalRow<'a> {
    goal: &'a Goal,
    lines: Vec<String>,
    count: Option<String>,
    /// Who or what the goal needs, under its text.
    needs: Option<String>,
}

/// Draws the panel at `scale` (1 suits a 1080-line window).
pub fn draw(view: &View, fonts: &mut Fonts, scale: f32) -> Pixmap {
    let k = scale;
    let (width, pad) = ((WIDTH * k).round(), PAD * k);
    let inner = width - pad * 2.0;
    let (small, body, title, big) = (12.5 * k, 14.0 * k, 16.0 * k, 26.0 * k);
    let (small_line, body_line) = (18.0 * k, 20.0 * k);

    let snapshot = match view {
        View::Live(snapshot) => *snapshot,
        View::Waiting(why) => {
            let lines = fonts.wrap(Weight::Regular, small, why, inner, 3);
            let height = (pad * 2.0 + body_line + lines.len() as f32 * small_line).ceil();
            let mut pixmap = Pixmap::new(width as u32, height as u32).expect("the panel has a size");
            fill(&mut pixmap, &rounded(0.5, 0.5, width - 1.0, height - 1.0, 11.0 * k), PANEL);
            fonts.draw(&mut pixmap, Weight::Bold, body, pad, pad + fonts.ascent(Weight::Bold, body), BRIGHT, "Polestar");
            let mut y = pad + body_line;
            for line in &lines {
                fonts.draw(&mut pixmap, Weight::Regular, small, pad, y + fonts.ascent(Weight::Regular, small), SOFT, line);
                y += small_line;
            }
            return pixmap;
        }
    };

    // Lay the text out first: the panel is as tall as what it has to say.
    let (head, detail) = headline(snapshot);
    let text_x = pad + DIAL * k + 14.0 * k;
    let text_w = width - pad - text_x;
    let place = snapshot.nav.target.as_ref().and_then(|t| match (t.map_x, t.map_y, &t.zone) {
        (Some(x), Some(y), Some(zone)) => Some(format!("{x:.1}, {y:.1}  {zone}")),
        (Some(x), Some(y), None) => Some(format!("{x:.1}, {y:.1}")),
        _ => None,
    });

    let quest = snapshot.quest.as_ref().and_then(|q| q.title.clone());
    let step = snapshot.step.as_ref().map(|step| {
        let mut text = format!("Step {}", step.number.unwrap_or(step.index));
        if let Some(total) = step.total {
            text.push_str(&format!(" of {total}"));
        }
        (text, step.title.clone())
    });
    // Without a quest the step's title is the heading.
    let heading = quest.clone().or_else(|| step.as_ref().and_then(|(_, title)| title.clone()));
    let under = step.as_ref().map(|(number, title)| match (&quest, title) {
        // A step named after its quest would only say the heading twice.
        (Some(quest), Some(title)) if quest != title => format!("{number}  ·  {title}"),
        _ => number.clone(),
    });

    let mark_w = 15.0 * k;
    let rows: Vec<GoalRow> = snapshot
        .goals
        .iter()
        .filter(|goal| goal.status != "done" && goal.status != "skipped")
        .take(MAX_GOALS)
        .map(|goal| {
            let count = goal.have.zip(goal.need).map(|(have, need)| format!("{have}/{need}"));
            let count_w = count.as_ref().map_or(0.0, |c| fonts.width(Weight::Bold, body, c) + 10.0 * k);
            let lines = fonts.wrap(Weight::Regular, body, &goal.text, inner - mark_w - count_w, if goal.current { 2 } else { 1 });
            let needs = goal.needs.as_ref().map(|needs| fonts.fit(Weight::Regular, small, needs, inner - mark_w));
            GoalRow { goal, lines, count, needs }
        })
        .collect();

    let notice = match snapshot.status.as_str() {
        "ok" => None,
        "no-guide" => Some("Polestar has no guide open".to_string()),
        "no-polestar" => Some("Polestar is not loaded".to_string()),
        "no-engine" => Some("Polestar's guide engine was not found".to_string()),
        other => Some(format!("Add-on: {other}")),
    };
    let warning = (!snapshot.missing_calls.is_empty()).then(|| "Polestar changed: some data is missing".to_string());

    // The path ahead, while there is one to walk.
    let preview = route::preview(snapshot).filter(|_| matches!(snapshot.nav.state.as_str(), "travel" | "instruction" | "search"));

    let guide_block = heading.is_some() || under.is_some() || !rows.is_empty() || notice.is_some();
    let mut height = pad + DIAL * k + pad;
    if preview.is_some() {
        height += (ROUTE * k).round() + pad;
    }
    if guide_block {
        height += 12.0 * k;
        height += heading.as_ref().map_or(0.0, |_| body_line + 2.0 * k);
        height += under.as_ref().map_or(0.0, |_| small_line);
        height += notice.as_ref().map_or(0.0, |_| small_line);
        if !rows.is_empty() {
            height += 6.0 * k
                + rows.iter().map(|row| row.lines.len().max(1) as f32 * body_line + row.needs.as_ref().map_or(0.0, |_| small_line)).sum::<f32>();
        }
    }
    height += warning.as_ref().map_or(0.0, |_| small_line + 2.0 * k);
    if guide_block || warning.is_some() {
        height += pad * 0.7;
    }
    let height = height.ceil();

    let mut pixmap = Pixmap::new(width as u32, height as u32).expect("the panel has a size");
    fill(&mut pixmap, &rounded(0.5, 0.5, width - 1.0, height - 1.0, 11.0 * k), PANEL);
    stroke(&mut pixmap, &rounded(0.5, 0.5, width - 1.0, height - 1.0, 11.0 * k), EDGE, 1.0);

    // Arrow and distance.
    let (cx, cy) = (pad + DIAL * k / 2.0, pad + DIAL * k / 2.0);
    dial(&mut pixmap, snapshot, cx, cy, DIAL * k / 2.0 - 1.0 * k, k);
    let lines_here = 1 + usize::from(!detail.is_empty()) + usize::from(place.is_some());
    let block = big * 0.95 + (lines_here - 1) as f32 * small_line;
    let mut y = cy - block / 2.0;
    let head = fonts.fit(Weight::Bold, big, &head, text_w);
    fonts.draw(&mut pixmap, Weight::Bold, big, text_x, y + big * 0.80, BRIGHT, &head);
    y += big * 0.95;
    if !detail.is_empty() {
        let detail = fonts.fit(Weight::Regular, small, &detail, text_w);
        fonts.draw(&mut pixmap, Weight::Regular, small, text_x, y + fonts.ascent(Weight::Regular, small), SOFT, &detail);
        y += small_line;
    }
    if let Some(place) = &place {
        let place = fonts.fit(Weight::Regular, small, place, text_w);
        fonts.draw(&mut pixmap, Weight::Regular, small, text_x, y + fonts.ascent(Weight::Regular, small), DIM, &place);
    }

    // The route view, with the next turn written over its top-left corner.
    let mut y = pad + DIAL * k + pad;
    if let Some(preview) = &preview {
        let (view, range) = route_view(preview, inner.round(), (ROUTE * k).round(), k);
        pixmap.draw_pixmap(pad.round() as i32, y.round() as i32, view.as_ref(), &PixmapPaint::default(), Transform::identity(), None);
        let turn = route::describe(preview.turn, preview.remaining);
        fonts.draw(&mut pixmap, Weight::Bold, small, pad + 9.0 * k, y + 7.0 * k + fonts.ascent(Weight::Bold, small), BRIGHT, &turn);
        let reach = format!("{range:.0} yd{}", if preview.heading_up { "" } else { "  ·  north up" });
        let x = width - pad - 9.0 * k - fonts.width(Weight::Regular, small, &reach);
        fonts.draw(&mut pixmap, Weight::Regular, small, x, y + 7.0 * k + fonts.ascent(Weight::Regular, small), DIM, &reach);
        y += (ROUTE * k).round() + pad;
    }

    // Quest, step and goals.
    if guide_block {
        stroke(&mut pixmap, &line((pad, y), (width - pad, y)), [255, 255, 255, 28], 1.0);
        y += 12.0 * k;
        if let Some(heading) = &heading {
            let heading = fonts.fit(Weight::Bold, title, heading, inner);
            fonts.draw(&mut pixmap, Weight::Bold, title, pad, y + fonts.ascent(Weight::Bold, title), GOLD, &heading);
            y += body_line + 2.0 * k;
        }
        if let Some(under) = &under {
            let under = fonts.fit(Weight::Regular, small, under, inner);
            fonts.draw(&mut pixmap, Weight::Regular, small, pad, y + fonts.ascent(Weight::Regular, small), DIM, &under);
            y += small_line;
        }
        if let Some(notice) = &notice {
            fonts.draw(&mut pixmap, Weight::Regular, small, pad, y + fonts.ascent(Weight::Regular, small), SOFT, notice);
            y += small_line;
        }
        if !rows.is_empty() {
            y += 6.0 * k;
            for row in &rows {
                let colour = if row.goal.current { BRIGHT } else { SOFT };
                mark(&mut pixmap, row.goal, pad, y + body_line * 0.52, k);
                if let Some(count) = &row.count {
                    let x = width - pad - fonts.width(Weight::Bold, body, count);
                    fonts.draw(&mut pixmap, Weight::Bold, body, x, y + fonts.ascent(Weight::Bold, body), colour, count);
                }
                for text in &row.lines {
                    fonts.draw(&mut pixmap, Weight::Regular, body, pad + mark_w, y + fonts.ascent(Weight::Regular, body), colour, text);
                    y += body_line;
                }
                if row.lines.is_empty() {
                    y += body_line;
                }
                if let Some(needs) = &row.needs {
                    fonts.draw(&mut pixmap, Weight::Regular, small, pad + mark_w, y - 2.0 * k + fonts.ascent(Weight::Regular, small), DIM, needs);
                    y += small_line;
                }
            }
        }
    }
    if let Some(warning) = &warning {
        y += 2.0 * k;
        fonts.draw(&mut pixmap, Weight::Regular, small, pad, y + fonts.ascent(Weight::Regular, small), RED, warning);
    }
    pixmap
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Nav, Player, Quest, Route, Step, Target};

    fn sample() -> Snapshot {
        Snapshot {
            status: "ok".into(),
            quest: Some(Quest { id: 844, title: Some("Plainstrider Menace".into()) }),
            step: Some(Step { index: 16, number: Some(3), total: Some(104), title: Some("Finish the Plainstrider Beaks".into()), ..Step::default() }),
            goals: vec![
                Goal { index: 1, kind: "collect".into(), status: "active".into(), have: Some(4), need: Some(7), current: true,
                    text: "Kill Greater Plainstrider or Ornery Plainstrider for Plainstrider Beak".into(), ..Goal::default() },
                Goal { index: 2, kind: "turnin".into(), status: "pending".into(), text: "Turn in Plainstrider Menace".into(), ..Goal::default() },
                Goal { index: 3, kind: "accept".into(), status: "done".into(), text: "Accept something".into(), ..Goal::default() },
            ],
            nav: Nav {
                state: "travel".into(),
                distance_yd: Some(531.4),
                along_path: true,
                bearing_deg: Some(47.0),
                bearing: Some("NE"),
                turn_deg: Some(45.0),
                target: Some(Target { map_x: Some(53.0), map_y: Some(21.0), zone: Some("The Barrens".into()), ..Target::default() }),
                ..Nav::default()
            },
            ..Snapshot::default()
        }
    }

    fn inked(pixmap: &Pixmap, colour: Colour) -> usize {
        pixmap.data().chunks_exact(4).filter(|p| p[3] == 255 && p[0] == colour[0] && p[1] == colour[1] && p[2] == colour[2]).count()
    }

    #[test]
    fn headlines_follow_the_arrow_state() {
        let mut s = sample();
        assert_eq!(headline(&s), ("531 yd".to_string(), "right 45°  ·  NE 047°  ·  by path".to_string()));
        s.nav.turn_deg = Some(-120.0);
        s.nav.along_path = false;
        assert_eq!(headline(&s).1, "left 120°  ·  NE 047°");
        s.nav.state = "arrived".into();
        assert_eq!(headline(&s).0, "Arrived");
        s.nav.state = "taxi".into();
        assert_eq!(headline(&s), ("On a flight".to_string(), String::new()));
        s.nav = Nav::default();
        assert_eq!(headline(&s).0, "No target");
    }

    #[test]
    fn the_panel_grows_with_what_it_shows() {
        let mut fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let full = draw(&View::Live(&sample()), &mut fonts, 1.0);
        assert_eq!(full.width(), 372);
        // The arrow is gold while travelling, green on arrival.
        assert!(inked(&full, GOLD) > 200 && inked(&full, GREEN) == 0);
        let mut arrived = sample();
        arrived.nav.state = "arrived".into();
        assert!(inked(&draw(&View::Live(&arrived), &mut fonts, 1.0), GREEN) > 200);

        let mut bare = sample();
        bare.goals.clear();
        bare.quest = None;
        bare.step = None;
        let bare = draw(&View::Live(&bare), &mut fonts, 1.0);
        assert!(bare.height() < full.height());

        let doubled = draw(&View::Live(&sample()), &mut fonts, 2.0);
        assert_eq!(doubled.width(), 744);
        assert!(doubled.height().abs_diff(full.height() * 2) <= 2);

        let waiting = draw(&View::Waiting("Waiting for the Polestar Link strip (/plk on in the game)"), &mut fonts, 1.0);
        assert!(waiting.height() < 100 && waiting.data().chunks_exact(4).any(|p| p[3] > 0));
    }

    #[test]
    fn a_goal_that_needs_someone_gets_a_line_for_it() {
        let mut fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let plain = draw(&View::Live(&sample()), &mut fonts, 1.0);
        let mut named = sample();
        named.goals[0].needs = Some("kill Zhevra Runner or Zhevra Charger".into());
        assert_eq!(draw(&View::Live(&named), &mut fonts, 1.0).height(), plain.height() + 18);
    }

    #[test]
    fn a_walking_path_adds_the_route_view() {
        let mut fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let plain = draw(&View::Live(&sample()), &mut fonts, 1.0);

        let mut walking = sample();
        walking.player = Player { continent: Some(1), world_north: Some(0.0), world_west: Some(0.0), heading_deg: Some(0.0), ..Player::default() };
        walking.nav.route = Some(Route { continent: 1, points: vec![[0.0, 0.0], [40.0, 0.0], [40.0, -30.0]] });
        let with_route = draw(&View::Live(&walking), &mut fonts, 1.0);
        assert_eq!(with_route.height(), plain.height() + 104 + 14);
        // The path's end is in view, so its green mark is drawn.
        assert!(inked(&with_route, GREEN) > 20);

        // Arrived: the path is done with, the view goes.
        walking.nav.state = "arrived".into();
        assert_eq!(draw(&View::Live(&walking), &mut fonts, 1.0).height(), plain.height());
    }

    #[test]
    fn the_route_view_picks_a_range_that_holds_the_path() {
        let preview = |yards: f64| Preview { points: vec![(0.0, 0.0), (0.0, yards)], remaining: yards, turn: None, heading_up: true };
        assert_eq!(route_view(&preview(35.0), 344.0, 104.0, 1.0).1, 40.0);
        assert_eq!(route_view(&preview(100.0), 344.0, 104.0, 1.0).1, 130.0);
        assert_eq!(route_view(&preview(900.0), 344.0, 104.0, 1.0).1, 250.0);
    }

    #[test]
    fn corners_stay_transparent() {
        let mut fonts = Fonts::load().expect("Segoe UI or Arial is installed");
        let pixmap = draw(&View::Live(&sample()), &mut fonts, 1.0);
        assert_eq!(pixmap.pixel(0, 0).unwrap().alpha(), 0);
        assert!(pixmap.pixel(pixmap.width() / 2, 3).unwrap().alpha() > 150);
    }
}
