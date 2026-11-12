//! The terminal view of a snapshot.

use std::fmt::Write;

use crate::model::{Goal, Snapshot};

fn arrow(turn_deg: f64) -> &'static str {
    const ARROWS: [&str; 8] = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"];
    ARROWS[((turn_deg.rem_euclid(360.0) + 22.5) / 45.0) as usize % 8]
}

fn turn(turn_deg: f64) -> String {
    let size = turn_deg.abs().round();
    if size < 3.0 {
        "straight ahead".to_string()
    } else if size > 177.0 {
        "behind you".to_string()
    } else if turn_deg > 0.0 {
        format!("turn right {size:.0}°")
    } else {
        format!("turn left {size:.0}°")
    }
}

fn state(name: &str) -> &str {
    match name {
        "travel" => "on the way",
        "arrived" => "arrived",
        "search" => "in the area: look around",
        "far" => "on another continent",
        "instruction" => "follow the travel instruction",
        "taxi" => "on a flight",
        "instance" => "in an instance",
        "nopos" => "no position here",
        "unknown" => "target not resolved",
        "none" | "" => "no target",
        other => other,
    }
}

fn goal_line(goal: &Goal) -> String {
    let mark = match goal.status.as_str() {
        "done" => "✓",
        "skipped" => "–",
        "active" => "•",
        _ => "·",
    };
    let pointer = if goal.current { "▶" } else { " " };
    let count = match (goal.have, goal.need) {
        (Some(have), Some(need)) => format!("  {have}/{need}"),
        _ => String::new(),
    };
    let needs = goal.needs.as_ref().map_or(String::new(), |needs| format!("  ({needs})"));
    format!("  {pointer} {mark} {}{count}{needs}", goal.text)
}

/// What to say when Polestar is not the version this program was checked
/// against: loudly when calls are gone, in passing when all are still there.
fn polestar_warning(s: &Snapshot) -> Vec<String> {
    let version = s.polestar_version.as_deref().unwrap_or("(version unknown)");
    if !s.missing_calls.is_empty() {
        return vec![
            format!("! Polestar {version} no longer has: {}", s.missing_calls.join(", ")),
            format!("! Data from those calls is missing below. polestar-plus was checked against Polestar {}.", s.polestar_tested),
            String::new(),
        ];
    }
    if s.untested_polestar() {
        return vec![
            format!("Polestar {version} in the game; checked against {}. Every call polestar-plus makes is still there.", s.polestar_tested),
            String::new(),
        ];
    }
    Vec::new()
}

/// The snapshot as lines of text.
pub fn dashboard(s: &Snapshot) -> Vec<String> {
    let mut lines = Vec::new();
    let p = &s.player;

    let mut who = String::from("Polestar");
    if let Some(name) = &p.name {
        let _ = write!(who, "  ·  {name}");
        if let Some(level) = p.level {
            let _ = write!(who, " ({level})");
        }
    }
    match (&p.zone, &p.subzone) {
        (Some(zone), Some(sub)) => {
            let _ = write!(who, "  ·  {zone}, {sub}");
        }
        (Some(zone), None) => {
            let _ = write!(who, "  ·  {zone}");
        }
        _ => {}
    }
    lines.push(who);
    lines.push(String::new());

    match s.status.as_str() {
        "ok" => {}
        "no-polestar" => lines.push("Polestar is not loaded in the game.".to_string()),
        "no-guide" => lines.push("Polestar has no guide open.".to_string()),
        "no-engine" => lines.push("Polestar is loaded but its guide engine was not found.".to_string()),
        other => lines.push(format!("Add-on status: {other}")),
    }
    lines.extend(polestar_warning(s));

    if let Some(guide) = &s.guide {
        let mut line = format!("Guide   {}", guide.title.as_deref().unwrap_or(&guide.id));
        if let (Some(done), Some(total)) = (guide.done, guide.total) {
            if total > 0 {
                let _ = write!(line, "   {done}/{total} done ({:.0}%)", done as f64 / total as f64 * 100.0);
            }
        }
        lines.push(line);
    }
    if let Some(step) = &s.step {
        let mut line = format!("Step    {}", step.number.unwrap_or(step.index));
        if let Some(total) = step.total {
            let _ = write!(line, " of {total}");
        }
        if let Some(title) = &step.title {
            let _ = write!(line, "   {title}");
        }
        if step.live.is_some_and(|live| live != step.index) {
            line.push_str("   (looking ahead or back: not the live step)");
        }
        lines.push(line);
    }
    if let Some(quest) = &s.quest {
        lines.push(format!("Quest   {}  [{}]", quest.title.as_deref().unwrap_or("(title not known yet)"), quest.id));
    }
    if !s.goals.is_empty() {
        lines.push("Goals".to_string());
        lines.extend(s.goals.iter().map(goal_line));
    }
    if let Some(note) = s.step.as_ref().and_then(|step| step.note.as_ref()) {
        lines.push(format!("Note    {note}"));
    }
    lines.push(String::new());

    let nav = &s.nav;
    let mut line = format!("Arrow   {}", state(&nav.state));
    if let Some(turn_deg) = nav.turn_deg {
        line = format!("Arrow   {}  {}", arrow(turn_deg), state(&nav.state));
        let _ = write!(line, "  ·  {}", turn(turn_deg));
    }
    if let Some(distance) = nav.distance_yd {
        let _ = write!(line, "  ·  {distance:.0} yd{}", if nav.along_path { " along the path" } else { "" });
    }
    if let (Some(deg), Some(point)) = (nav.bearing_deg, nav.bearing) {
        let _ = write!(line, "  ·  bearing {deg:03.0}° {point}");
    }
    if let Some(floor) = &nav.floor {
        let _ = write!(line, "  ·  go {floor} a floor");
    }
    lines.push(line);

    if let Some(preview) = crate::route::preview(s) {
        lines.push(format!("Route   {}", crate::route::describe(preview.turn, preview.remaining)));
    }

    if let Some(target) = &nav.target {
        let mut line = format!("Target  {}", target.label.as_deref().unwrap_or("(unnamed)"));
        if let Some(kind) = &target.kind {
            let _ = write!(line, " ({kind})");
        }
        if let (Some(x), Some(y)) = (target.map_x, target.map_y) {
            let _ = write!(line, "  ·  {x:.1}, {y:.1}");
            if let Some(zone) = &target.zone {
                let _ = write!(line, " in {zone}");
            }
        }
        if let (Some(yards), Some(deg), Some(point)) = (target.straight_yd, target.bearing_deg, target.bearing) {
            let _ = write!(line, "  ·  {yards:.0} yd straight, bearing {deg:03.0}° {point}");
        }
        lines.push(line);
    }

    let mut line = String::from("You     ");
    match (p.map_x, p.map_y) {
        (Some(x), Some(y)) => {
            let _ = write!(line, "{x:.1}, {y:.1}");
        }
        _ => line.push_str("position not given here"),
    }
    if let (Some(deg), Some(point)) = (p.heading_deg, p.heading) {
        let _ = write!(line, "  ·  facing {deg:03.0}° {point}");
    }
    lines.push(line);
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warns_about_a_changed_polestar() {
        let tested = crate::model::TESTED_POLESTAR;
        let mut s = Snapshot { status: "ok".into(), polestar_version: Some(tested.into()), ..Snapshot::default() };
        assert!(polestar_warning(&s).is_empty());
        s.polestar_version = Some("0.4.0".into());
        assert!(polestar_warning(&s)[0].starts_with("Polestar 0.4.0 in the game; checked against"));
        s.missing_calls = vec!["Nav.Sample".into()];
        assert_eq!(polestar_warning(&s)[0], "! Polestar 0.4.0 no longer has: Nav.Sample");
        assert!(dashboard(&s).iter().any(|line| line.starts_with("! Polestar 0.4.0")));
    }

    #[test]
    fn arrows_follow_the_turn() {
        assert_eq!(arrow(0.0), "↑");
        assert_eq!(arrow(44.0), "↗");
        assert_eq!(arrow(-90.0), "←");
        assert_eq!(arrow(180.0), "↓");
        assert_eq!(arrow(-10.0), "↑");
    }

    #[test]
    fn turns_read_naturally() {
        assert_eq!(turn(1.0), "straight ahead");
        assert_eq!(turn(32.4), "turn right 32°");
        assert_eq!(turn(-120.0), "turn left 120°");
        assert_eq!(turn(179.0), "behind you");
    }
}
