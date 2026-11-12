//! Polestar's walking path as the player sees it: what is left of it, turned
//! so the way the character faces is up, and the first real bend in it.

use crate::model::Snapshot;

/// Further than this from the path and it is not the one being walked.
const OFF_PATH: f64 = 60.0;
/// Bends are looked for on the path resampled this often, over chords this long.
const STEP: f64 = 4.0;
const CHORD: usize = 3;
/// A bend counts as a turn from this many degrees, if it lasts.
const TURN: f64 = 40.0;
/// This close to the path's end, a bend is just the way in to the target.
const ARRIVAL: f64 = 15.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Turn {
    /// Yards along the path to the bend.
    pub in_yd: f64,
    /// How far the path swings: positive right, negative left.
    pub deg: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Preview {
    /// The path from the player onwards, in yards: (right, ahead) of the
    /// player, or (east, north) when the facing is not known.
    pub points: Vec<(f64, f64)>,
    /// Yards of path left.
    pub remaining: f64,
    pub turn: Option<Turn>,
    /// `points` are turned to the character's facing (else north is up).
    pub heading_up: bool,
}

fn length(points: &[(f64, f64)]) -> f64 {
    points.windows(2).map(|w| (w[1].0 - w[0].0).hypot(w[1].1 - w[0].1)).sum()
}

/// The path from the point on it nearest `at` onwards; `None` when `at` is
/// too far from every part of it.
fn ahead(path: &[(f64, f64)], at: (f64, f64)) -> Option<Vec<(f64, f64)>> {
    let mut best: Option<(f64, usize, (f64, f64))> = None;
    for (i, w) in path.windows(2).enumerate() {
        let (ax, ay, bx, by) = (w[0].0, w[0].1, w[1].0, w[1].1);
        let (dx, dy) = (bx - ax, by - ay);
        let span = dx * dx + dy * dy;
        let t = if span > 0.0 { (((at.0 - ax) * dx + (at.1 - ay) * dy) / span).clamp(0.0, 1.0) } else { 0.0 };
        let foot = (ax + dx * t, ay + dy * t);
        let off = (foot.0 - at.0).hypot(foot.1 - at.1);
        // On a tie the later segment wins: a path that doubles back is
        // being walked on its way out.
        if best.map_or(true, |(least, _, _)| off <= least) {
            best = Some((off, i, foot));
        }
    }
    let (off, i, foot) = best?;
    if off > OFF_PATH {
        return None;
    }
    let mut out = vec![foot];
    out.extend_from_slice(&path[i + 1..]);
    Some(out)
}

/// Points every `STEP` yards along the path, the first being its start.
fn resample(points: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let mut out = vec![points[0]];
    let mut need = STEP;
    for w in points.windows(2) {
        let span = (w[1].0 - w[0].0).hypot(w[1].1 - w[0].1);
        let mut done = 0.0;
        while span - done >= need {
            done += need;
            let t = done / span;
            out.push((w[0].0 + (w[1].0 - w[0].0) * t, w[0].1 + (w[1].1 - w[0].1) * t));
            need = STEP;
        }
        need -= span - done;
    }
    out
}

fn wrap(deg: f64) -> f64 {
    let d = deg.rem_euclid(360.0);
    if d > 180.0 { d - 360.0 } else { d }
}

/// The first place the path swings away from the way it sets out and stays
/// swung: grid paths wiggle, and a wiggle is not a turn.
pub fn next_turn(points: &[(f64, f64)]) -> Option<Turn> {
    if points.len() < 2 {
        return None;
    }
    let samples = resample(points);
    if samples.len() <= CHORD * 2 {
        return None;
    }
    let heading = |i: usize| (samples[i + CHORD].0 - samples[i].0).atan2(samples[i + CHORD].1 - samples[i].1).to_degrees();
    let start = heading(0);
    let last = samples.len() - 1 - CHORD;
    for i in 1..=last {
        let swing = wrap(heading(i) - start);
        if swing.abs() < TURN {
            continue;
        }
        let after = wrap(heading((i + CHORD).min(last)) - start);
        if after.abs() >= TURN * 0.75 && after.signum() == swing.signum() {
            let deg = if after.abs() > swing.abs() { after } else { swing };
            return Some(Turn { in_yd: (i as f64 + CHORD as f64 / 2.0) * STEP, deg });
        }
    }
    None
}

/// What is left of the route in the snapshot, as the player sees it.
pub fn preview(s: &Snapshot) -> Option<Preview> {
    let route = s.nav.route.as_ref()?;
    let (north, west) = (s.player.world_north?, s.player.world_west?);
    if s.player.continent != Some(route.continent) || route.points.len() < 2 {
        return None;
    }
    // East and north of the player.
    let path: Vec<(f64, f64)> = route.points.iter().map(|p| (-(p[1] - west), p[0] - north)).collect();
    let mut left = ahead(&path, (0.0, 0.0))?;
    let remaining = length(&left);
    if remaining < 1.0 {
        return None;
    }
    // A bend in the last few yards is the arrival, not a turn to announce.
    let turn = next_turn(&left).filter(|turn| turn.in_yd < remaining - ARRIVAL);
    let heading_up = s.player.heading_deg.is_some();
    if let Some(heading) = s.player.heading_deg {
        let (sin, cos) = heading.to_radians().sin_cos();
        for p in &mut left {
            *p = (p.0 * cos - p.1 * sin, p.0 * sin + p.1 * cos);
        }
    }
    Some(Preview { points: left, remaining, turn, heading_up })
}

/// How the turn reads on the panel.
pub fn describe(turn: Option<Turn>, remaining: f64) -> String {
    match turn {
        Some(turn) => {
            let side = if turn.deg > 0.0 { "right" } else { "left" };
            let kind = match turn.deg.abs() {
                d if d >= 100.0 => format!("Sharp {side}"),
                d if d >= 60.0 => format!("Turn {side}"),
                _ => format!("Bear {side}"),
            };
            if turn.in_yd < 10.0 { format!("{kind} now") } else { format!("{kind} in {:.0} yd", turn.in_yd) }
        }
        None => format!("Straight on, {remaining:.0} yd of path"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Route;

    fn snapshot(points: &[[f64; 2]], at: (f64, f64), heading: Option<f64>) -> Snapshot {
        let mut s = Snapshot::default();
        s.player.continent = Some(1);
        s.player.world_north = Some(at.0);
        s.player.world_west = Some(at.1);
        s.player.heading_deg = heading;
        s.nav.route = Some(Route { continent: 1, points: points.to_vec() });
        s
    }

    #[test]
    fn a_straight_path_has_no_turn() {
        // 100 yd due north, the player 30 yd along it and 2 yd to one side, facing north.
        let p = preview(&snapshot(&[[0.0, 0.0], [100.0, 0.0]], (30.0, 2.0), Some(0.0))).unwrap();
        assert!((p.remaining - 70.0).abs() < 0.01 && p.turn.is_none() && p.heading_up);
        // West is +2 from the path's point of view, so the path is 2 yd to the player's right.
        assert!((p.points[0].0 - 2.0).abs() < 0.01 && p.points[0].1.abs() < 0.01);
        assert!((p.points[1].1 - 70.0).abs() < 0.01);
        assert_eq!(describe(p.turn, p.remaining), "Straight on, 70 yd of path");
    }

    #[test]
    fn a_corner_is_a_turn_and_a_wiggle_is_not() {
        // North 60 yd, then east (west negative) 60 yd: a right turn.
        let corner = [[0.0, 0.0], [60.0, 0.0], [60.0, -60.0]];
        let p = preview(&snapshot(&corner, (0.0, 0.0), Some(0.0))).unwrap();
        let turn = p.turn.unwrap();
        assert!(turn.deg > 60.0 && (turn.in_yd - 60.0).abs() < 12.0, "{turn:?}");
        assert!(describe(p.turn, p.remaining).starts_with("Turn right in "));

        // The same corner walked the other way round is a left turn.
        let left = [[0.0, 0.0], [60.0, 0.0], [60.0, 60.0]];
        assert!(preview(&snapshot(&left, (0.0, 0.0), Some(0.0))).unwrap().turn.unwrap().deg < -60.0);

        // A grid path stepping one cell sideways every few cells keeps its heading.
        let wiggle: Vec<[f64; 2]> = (0..30).map(|i| [i as f64 * 4.0, if i % 4 < 2 { 0.0 } else { 3.0 }]).collect();
        assert!(preview(&snapshot(&wiggle, (0.0, 0.0), Some(0.0))).unwrap().turn.is_none());
    }

    #[test]
    fn a_bend_at_the_very_end_is_not_announced() {
        // 240 yd straight, then the last 8 yd off to one side to reach the target.
        let hook = [[0.0, 0.0], [240.0, 0.0], [240.0, -8.0]];
        let p = preview(&snapshot(&hook, (0.0, 0.0), Some(0.0))).unwrap();
        assert!(p.turn.is_none(), "{:?}", p.turn);
        assert_eq!(describe(p.turn, p.remaining), "Straight on, 248 yd of path");
    }

    #[test]
    fn the_view_turns_with_the_character() {
        // The path runs north; the character faces east, so it leads off to their left.
        let p = preview(&snapshot(&[[0.0, 0.0], [50.0, 0.0]], (0.0, 0.0), Some(90.0))).unwrap();
        let end = p.points[1];
        assert!((end.0 + 50.0).abs() < 0.01 && end.1.abs() < 0.01, "{end:?}");
        // Facing unknown: north stays up.
        let p = preview(&snapshot(&[[0.0, 0.0], [50.0, 0.0]], (0.0, 0.0), None)).unwrap();
        assert!(!p.heading_up && (p.points[1].1 - 50.0).abs() < 0.01);
    }

    #[test]
    fn no_preview_off_the_path_or_on_another_continent() {
        let path = [[0.0, 0.0], [100.0, 0.0]];
        assert!(preview(&snapshot(&path, (50.0, 80.0), Some(0.0))).is_none());
        let mut elsewhere = snapshot(&path, (50.0, 0.0), Some(0.0));
        elsewhere.player.continent = Some(0);
        assert!(preview(&elsewhere).is_none());
        // At the very end there is nothing left to show.
        assert!(preview(&snapshot(&path, (100.0, 0.0), Some(0.0))).is_none());
    }

    #[test]
    fn turns_are_worded_by_how_hard_they_are() {
        assert_eq!(describe(Some(Turn { in_yd: 42.0, deg: 45.0 }), 200.0), "Bear right in 42 yd");
        assert_eq!(describe(Some(Turn { in_yd: 42.0, deg: -90.0 }), 200.0), "Turn left in 42 yd");
        assert_eq!(describe(Some(Turn { in_yd: 6.0, deg: -140.0 }), 200.0), "Sharp left now");
    }
}
