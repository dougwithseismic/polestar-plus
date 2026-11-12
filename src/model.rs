//! What the strip's payload says, as one snapshot of Polestar.
//!
//! Angles: Polestar and the game measure facing in radians, 0 = north,
//! counter-clockwise positive, with world x running north and y running west.
//! Everything here is turned into compass degrees (0 = north, 90 = east) and
//! `turn_deg` (positive = turn right).

use serde::Serialize;

/// The Polestar version the add-on's calls were checked against in the game.
pub const TESTED_POLESTAR: &str = "0.3.5";

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Snapshot {
    /// "ok", "no-guide", "no-engine", "no-polestar" or "error: ..." from the add-on.
    pub status: String,
    /// Polestar's version in the game; `None` from an add-on too old to say.
    pub polestar_version: Option<String>,
    /// The version this program was checked against.
    pub polestar_tested: &'static str,
    /// Polestar functions the add-on calls that are no longer there
    /// ("Nav.Sample", or a whole part as "Engine"): the data they gave is missing.
    pub missing_calls: Vec<String>,
    pub player: Player,
    pub guide: Option<Guide>,
    pub step: Option<Step>,
    /// The quest of the goal the arrow leads to.
    pub quest: Option<Quest>,
    pub goals: Vec<Goal>,
    pub nav: Nav,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Player {
    pub name: Option<String>,
    pub level: Option<u32>,
    pub zone: Option<String>,
    pub subzone: Option<String>,
    pub continent: Option<i64>,
    /// World position in yards: north, west.
    pub world_north: Option<f64>,
    pub world_west: Option<f64>,
    pub map_id: Option<i64>,
    /// Map position in percent, as the game's map shows it.
    pub map_x: Option<f64>,
    pub map_y: Option<f64>,
    /// Compass heading the character faces.
    pub heading_deg: Option<f64>,
    pub heading: Option<&'static str>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Guide {
    pub id: String,
    pub title: Option<String>,
    pub done: Option<u32>,
    pub total: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Step {
    /// Index in the guide.
    pub index: u32,
    /// The number Polestar's window shows, out of `total`.
    pub number: Option<u32>,
    pub total: Option<u32>,
    /// The step the guide is really at, when the player is looking at another.
    pub live: Option<u32>,
    pub title: Option<String>,
    pub note: Option<String>,
    pub current_goal: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Quest {
    pub id: u32,
    pub title: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Goal {
    pub index: u32,
    /// accept, turnin, kill, collect, goto, ...
    pub kind: String,
    /// active, pending, done, skipped
    pub status: String,
    pub quest_id: Option<u32>,
    pub have: Option<u32>,
    pub need: Option<u32>,
    pub text: String,
    /// The goal the arrow leads to.
    pub current: bool,
    /// The NPC the goal names (the quest giver, the one to hand in to).
    pub npc: Option<String>,
    /// Where the goal's item comes from.
    pub source: Option<Source>,
    /// `npc` and `source` as one line, leaving out what `text` already says.
    pub needs: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Source {
    pub name: String,
    /// A second creature or object that gives the same thing.
    pub also: Option<String>,
    /// "npc" or "object".
    pub kind: Option<String>,
    /// It has to be killed for it.
    pub enemy: bool,
}

impl Goal {
    /// Who or what the goal needs, in words, without repeating its text.
    fn describe_needs(&self) -> Option<String> {
        let said = self.text.to_lowercase();
        let unsaid = |name: &str| !said.contains(&name.to_lowercase());
        let mut parts = Vec::new();
        if let Some(npc) = self.npc.as_deref().filter(|npc| unsaid(npc)) {
            parts.push(match self.kind.as_str() {
                "accept" => format!("from {npc}"),
                "turnin" => format!("to {npc}"),
                _ => format!("at {npc}"),
            });
        }
        if let Some(source) = self.source.as_ref().filter(|source| unsaid(&source.name)) {
            let names = match &source.also {
                Some(also) => format!("{} or {also}", source.name),
                None => source.name.clone(),
            };
            parts.push(if source.enemy {
                format!("kill {names}")
            } else if source.kind.as_deref() == Some("object") {
                format!("from {names} (an object)")
            } else {
                format!("from {names}")
            });
        }
        (!parts.is_empty()).then(|| parts.join("  ·  "))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Nav {
    /// Polestar's arrow state: travel, arrived, search, far, instruction,
    /// taxi, instance, nopos, unknown, none.
    pub state: String,
    /// Yards to what the arrow points at.
    pub distance_yd: Option<f64>,
    /// `distance_yd` is along Polestar's walking path, not a straight line.
    pub along_path: bool,
    /// Compass bearing of the arrow.
    pub bearing_deg: Option<f64>,
    pub bearing: Option<&'static str>,
    /// How far to turn to face the arrow: positive right, negative left.
    pub turn_deg: Option<f64>,
    /// "up" or "down" when the target is a floor away.
    pub floor: Option<String>,
    pub target: Option<Target>,
    /// The walking path Polestar draws on its map, from about where the
    /// player is on it; `None` when the current leg is not a walk.
    pub route: Option<Route>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Route {
    pub continent: i64,
    /// World points in whole yards: [north, west].
    pub points: Vec<[f64; 2]>,
}

/// Where the guide is sending the player: the destination, which the arrow's
/// next path point may not be.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Target {
    pub label: Option<String>,
    pub kind: Option<String>,
    pub zone: Option<String>,
    pub map_id: Option<i64>,
    pub map_x: Option<f64>,
    pub map_y: Option<f64>,
    pub continent: Option<i64>,
    pub world_north: Option<f64>,
    pub world_west: Option<f64>,
    pub world_height: Option<f64>,
    /// Straight-line yards and compass bearing from the player, on the same continent.
    pub straight_yd: Option<f64>,
    pub bearing_deg: Option<f64>,
    pub bearing: Option<&'static str>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            status: String::new(),
            polestar_version: None,
            polestar_tested: TESTED_POLESTAR,
            missing_calls: Vec::new(),
            player: Player::default(),
            guide: None,
            step: None,
            quest: None,
            goals: Vec::new(),
            nav: Nav::default(),
        }
    }
}

impl Snapshot {
    /// Polestar in the game is not the version this program was checked against.
    pub fn untested_polestar(&self) -> bool {
        self.polestar_version.as_deref().is_some_and(|v| v != TESTED_POLESTAR)
    }
}

pub fn compass(deg: f64) -> &'static str {
    const POINTS: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    POINTS[((deg.rem_euclid(360.0) + 22.5) / 45.0) as usize % 8]
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

/// Degrees as a compass reading: 0 up to, not including, 360, to a tenth.
fn compass_deg(deg: f64) -> f64 {
    let v = round1(deg.rem_euclid(360.0));
    // 359.96 rounds to 360, and a negative zero would print as "-0".
    if v >= 360.0 || v == 0.0 { 0.0 } else { v }
}

/// Compass bearing of an offset given in yards north and west.
fn bearing_of(north: f64, west: f64) -> f64 {
    compass_deg((-west).atan2(north).to_degrees())
}

fn text(s: &str) -> Option<String> {
    (!s.is_empty()).then(|| s.to_string())
}

fn numbers(s: &str) -> Vec<Option<f64>> {
    s.split(',').map(|part| part.trim().parse().ok()).collect()
}

fn whole(v: Option<f64>) -> Option<u32> {
    v.filter(|v| *v >= 0.0).map(|v| v as u32)
}

/// Reads the payload's fields. Unknown tags are skipped, so an add-on newer
/// than this program still reads.
pub fn parse(payload: &[u8]) -> Snapshot {
    let mut s = Snapshot::default();
    let mut target = Target::default();
    let mut has_target = false;
    let (mut step, mut guide) = (Step::default(), Guide::default());
    let (mut has_step, mut has_guide) = (false, false);
    let (mut north, mut west, mut turn_ccw): (Option<f64>, Option<f64>, Option<f64>) = (None, None, None);
    let (mut route_start, mut route_steps): (Option<(i64, f64, f64)>, &[u8]) = (None, &[]);
    let mut needs: Option<(u32, Option<String>, Option<Source>)> = None;

    let mut i = 0;
    while i + 2 <= payload.len() {
        let (tag, len) = (payload[i], payload[i + 1] as usize);
        let Some(raw) = payload.get(i + 2..i + 2 + len) else { break };
        i += 2 + len;
        let value = String::from_utf8_lossy(raw);
        let value = value.as_ref();
        match tag {
            b'E' => s.status = value.to_string(),
            b'V' => s.polestar_version = text(value),
            b'X' => s.missing_calls = value.split(',').filter(|name| !name.is_empty()).map(str::to_string).collect(),
            b'U' => {
                let (name, level) = value.split_once('|').unwrap_or((value, ""));
                s.player.name = text(name);
                s.player.level = level.parse().ok();
            }
            b'z' => {
                let (zone, sub) = value.split_once('|').unwrap_or((value, ""));
                s.player.zone = text(zone);
                s.player.subzone = text(sub);
            }
            b'F' => {
                if let Ok(facing) = value.parse::<f64>() {
                    let deg = compass_deg(-facing.to_degrees());
                    s.player.heading_deg = Some(deg);
                    s.player.heading = Some(compass(deg));
                }
            }
            b'P' => {
                if let [c, x, y] = numbers(value)[..] {
                    s.player.continent = c.map(|c| c as i64);
                    s.player.world_north = x;
                    s.player.world_west = y;
                }
            }
            b'Z' => {
                if let [map, x, y] = numbers(value)[..] {
                    s.player.map_id = map.map(|m| m as i64);
                    s.player.map_x = x;
                    s.player.map_y = y;
                }
            }
            b'S' => s.nav.state = value.to_string(),
            b'D' => s.nav.distance_yd = value.parse().ok(),
            b'M' => s.nav.along_path = value == "1",
            b'A' => turn_ccw = value.parse().ok(),
            b'N' => {
                if let [n, w] = numbers(value)[..] {
                    north = n;
                    west = w;
                }
            }
            b'f' => s.nav.floor = text(value),
            b'w' => {
                let parts: Vec<&str> = value.split('|').collect();
                if let [index, npc, from, also, kind, enemy] = parts[..] {
                    if let Ok(index) = index.parse() {
                        let source = text(from).map(|name| Source { name, also: text(also), kind: text(kind), enemy: enemy == "1" });
                        needs = Some((index, text(npc), source));
                    }
                }
            }
            b'r' => {
                if let [Some(c), Some(x), Some(y)] = numbers(value)[..] {
                    route_start = Some((c as i64, x, y));
                }
            }
            // Bytes, not text: two a point.
            b'p' => route_steps = raw,
            b'G' => {
                guide.id = value.to_string();
                has_guide = true;
            }
            b'g' => guide.title = text(value),
            b'R' => {
                if let [done, total] = numbers(value)[..] {
                    guide.done = whole(done);
                    guide.total = whole(total);
                }
            }
            b'I' => {
                if let [Some(index), number, total, live] = numbers(value)[..] {
                    step.index = index as u32;
                    step.number = whole(number);
                    step.total = whole(total);
                    step.live = whole(live);
                    has_step = true;
                }
            }
            b'H' => step.title = text(value),
            b'n' => step.note = text(value),
            b'C' => step.current_goal = value.parse().ok(),
            b'Q' => {
                let (id, title) = value.split_once('|').unwrap_or((value, ""));
                if let Ok(id) = id.parse() {
                    s.quest = Some(Quest { id, title: text(title) });
                }
            }
            b'L' => {
                target.label = text(value);
                has_target = true;
            }
            b'K' => {
                target.kind = text(value);
                has_target = true;
            }
            b'W' => target.zone = text(value),
            b't' => {
                if let [map, x, y] = numbers(value)[..] {
                    target.map_id = map.map(|m| m as i64);
                    target.map_x = x;
                    target.map_y = y;
                    has_target = true;
                }
            }
            b'T' => {
                if let [c, x, y, z] = numbers(value)[..] {
                    target.continent = c.map(|c| c as i64);
                    target.world_north = x;
                    target.world_west = y;
                    target.world_height = z;
                    has_target = true;
                }
            }
            b'O' => {
                let parts: Vec<&str> = value.splitn(7, '|').collect();
                if let [index, kind, status, quest, have, need, goal_text] = parts[..] {
                    if let Ok(index) = index.parse() {
                        s.goals.push(Goal {
                            index,
                            kind: kind.to_string(),
                            status: status.to_string(),
                            quest_id: quest.parse().ok(),
                            have: have.parse().ok(),
                            need: need.parse().ok(),
                            text: goal_text.to_string(),
                            ..Goal::default()
                        });
                    }
                }
            }
            _ => {}
        }
    }

    if let (Some(n), Some(w)) = (north, west) {
        let deg = bearing_of(n, w);
        s.nav.bearing_deg = Some(deg);
        s.nav.bearing = Some(compass(deg));
    }
    s.nav.turn_deg = turn_ccw.map(|rad| {
        let right = (-rad.to_degrees()).rem_euclid(360.0);
        round1(if right > 180.0 { right - 360.0 } else { right })
    });

    if let Some((continent, mut x, mut y)) = route_start {
        let mut points = vec![[x, y]];
        for step in route_steps.chunks_exact(2) {
            x += step[0] as f64 - 128.0;
            y += step[1] as f64 - 128.0;
            points.push([x, y]);
        }
        if points.len() > 1 {
            s.nav.route = Some(Route { continent, points });
        }
    }

    if has_target {
        if let (Some(tn), Some(tw), Some(pn), Some(pw)) =
            (target.world_north, target.world_west, s.player.world_north, s.player.world_west)
        {
            if target.continent.is_some() && target.continent == s.player.continent {
                let (n, w) = (tn - pn, tw - pw);
                let deg = bearing_of(n, w);
                target.straight_yd = Some(round1(n.hypot(w)));
                target.bearing_deg = Some(deg);
                target.bearing = Some(compass(deg));
            }
        }
        s.nav.target = Some(target);
    }
    if let Some((index, npc, source)) = needs {
        if let Some(goal) = s.goals.iter_mut().find(|goal| goal.index == index) {
            goal.npc = npc;
            goal.source = source;
            goal.needs = goal.describe_needs();
        }
    }
    if has_step {
        for goal in &mut s.goals {
            goal.current = Some(goal.index) == step.current_goal;
        }
        s.step = Some(step);
    }
    if has_guide {
        s.guide = Some(guide);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(list: &[(u8, &str)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (tag, value) in list {
            out.push(*tag);
            out.push(value.len() as u8);
            out.extend_from_slice(value.as_bytes());
        }
        out
    }

    #[test]
    fn reads_a_full_payload() {
        let s = parse(&fields(&[
            (b'S', "travel"),
            (b'D', "312.4"),
            (b'M', "1"),
            (b'A', "-0.7854"),
            (b'N', "100.0,-100.0"),
            (b'F', "1.5708"),
            (b'P', "1,-400.0,-2600.0"),
            (b'Z', "1413,52.10,30.05"),
            (b'E', "ok"),
            (b'U', "Aldric|14"),
            (b'z', "The Barrens|The Crossroads"),
            (b'L', "Sergra Darkthorn"),
            (b'K', "turnin"),
            (b't', "1413,52.23,31.01"),
            (b'T', "1,-100.0,-2600.0,91.7"),
            (b'G', "forever/horde/02-the-barrens"),
            (b'R', "40,163"),
            (b'I', "16,15,160,16"),
            (b'H', "The Crossroads"),
            (b'C', "2"),
            (b'Q', "844|Plainstrider Menace"),
            (b'O', "1|accept|done|844|||Accept Plainstrider Menace"),
            (b'O', "2|kill|active|844|3|7|Kill Plainstriders | for beaks"),
            (b'?', "a tag from a newer add-on"),
        ]));

        assert_eq!(s.status, "ok");
        assert_eq!(s.player.name.as_deref(), Some("Aldric"));
        assert_eq!(s.player.level, Some(14));
        assert_eq!(s.player.subzone.as_deref(), Some("The Crossroads"));
        // Facing a quarter turn counter-clockwise from north is west.
        assert_eq!(s.player.heading_deg, Some(270.0));
        assert_eq!(s.player.heading, Some("W"));

        assert_eq!(s.nav.state, "travel");
        assert!(s.nav.along_path);
        // 100 yd north and 100 yd east is north-east; the arrow is 45 degrees clockwise of facing.
        assert_eq!(s.nav.bearing_deg, Some(45.0));
        assert_eq!(s.nav.bearing, Some("NE"));
        assert_eq!(s.nav.turn_deg, Some(45.0));

        let target = s.nav.target.unwrap();
        assert_eq!(target.label.as_deref(), Some("Sergra Darkthorn"));
        assert_eq!(target.straight_yd, Some(300.0));
        assert_eq!(target.bearing, Some("N"));
        assert_eq!(target.world_height, Some(91.7));

        assert_eq!(s.guide.unwrap().total, Some(163));
        let step = s.step.unwrap();
        assert_eq!((step.index, step.number, step.total), (16, Some(15), Some(160)));
        assert_eq!(s.quest, Some(Quest { id: 844, title: Some("Plainstrider Menace".into()) }));

        assert_eq!(s.goals.len(), 2);
        assert!(!s.goals[0].current && s.goals[1].current);
        assert_eq!((s.goals[1].have, s.goals[1].need), (Some(3), Some(7)));
        assert_eq!(s.goals[1].text, "Kill Plainstriders | for beaks");
    }

    #[test]
    fn target_on_another_continent_has_no_bearing() {
        let s = parse(&fields(&[(b'P', "1,0.0,0.0"), (b'T', "0,50.0,50.0,")]));
        let target = s.nav.target.unwrap();
        assert_eq!((target.straight_yd, target.bearing_deg, target.world_height), (None, None, None));
    }

    #[test]
    fn truncated_payload_keeps_what_came_before() {
        let mut bytes = fields(&[(b'E', "no-guide")]);
        bytes.extend_from_slice(&[b'H', 200, b'x']);
        let s = parse(&bytes);
        assert_eq!(s.status, "no-guide");
        assert!(s.step.is_none() && s.guide.is_none() && s.nav.target.is_none());
    }

    #[test]
    fn what_a_goal_needs_leaves_out_what_its_text_says() {
        let goal = |kind: &str, text: &str, w: &str| {
            let line = format!("2|{kind}|active|844|||{text}");
            parse(&fields(&[(b'w', w), (b'O', line.as_str())])).goals.remove(0)
        };
        // The quest giver is not in the text: say who.
        assert_eq!(goal("accept", "Accept Path of Defense", "2|Thork||||0").needs.as_deref(), Some("from Thork"));
        assert_eq!(goal("turnin", "Turn in Veteran Uzzek", "2|Thork||||0").needs.as_deref(), Some("to Thork"));
        // A collect whose text names only the item: say what drops it.
        let hooves = goal("collect", "Collect Zhevra Hooves", "2||Zhevra Runner|Zhevra Charger|npc|1");
        assert_eq!(hooves.needs.as_deref(), Some("kill Zhevra Runner or Zhevra Charger"));
        assert_eq!(hooves.source.unwrap().also.as_deref(), Some("Zhevra Charger"));
        assert_eq!(goal("collect", "Collect Oats", "2||Sack of Oats||object|0").needs.as_deref(), Some("from Sack of Oats (an object)"));
        // The text already names the creature: nothing to add.
        assert_eq!(goal("collect", "Kill Greater Plainstrider for Plainstrider Beak", "2||Greater Plainstrider||npc|1").needs, None);
        // Both, and a field for a goal that is not listed is dropped.
        assert_eq!(goal("interact", "Search the supplies", "2|Guard|Crate||object|0").needs.as_deref(), Some("at Guard  ·  from Crate (an object)"));
        assert_eq!(goal("accept", "Accept X", "9|Thork||||0").needs, None);
    }

    #[test]
    fn route_points_add_up_from_the_start() {
        let mut bytes = fields(&[(b'r', "1,-400,-2600")]);
        // +10 north, then 127 north and 3 east, then 5 south.
        bytes.extend_from_slice(&[b'p', 6, 138, 128, 255, 125, 123, 128]);
        let route = parse(&bytes).nav.route.unwrap();
        assert_eq!(route.continent, 1);
        assert_eq!(route.points, [[-400.0, -2600.0], [-390.0, -2600.0], [-263.0, -2603.0], [-268.0, -2603.0]]);
        // A start with no steps is not a path.
        assert!(parse(&fields(&[(b'r', "1,-400,-2600")])).nav.route.is_none());
    }

    #[test]
    fn polestar_version_and_missing_calls() {
        let same = parse(&fields(&[(b'V', TESTED_POLESTAR)]));
        assert!(!same.untested_polestar() && same.missing_calls.is_empty());
        let newer = parse(&fields(&[(b'V', "0.4.0"), (b'X', "Nav.Sample,Compat")]));
        assert!(newer.untested_polestar());
        assert_eq!(newer.missing_calls, ["Nav.Sample", "Compat"]);
        // An add-on from before the version was published: nothing to flag.
        assert!(!parse(&fields(&[(b'E', "ok")])).untested_polestar());
    }

    #[test]
    fn due_north_is_plain_zero() {
        let s = parse(&fields(&[(b'P', "1,-400.0,-2600.0"), (b'T', "1,-100.0,-2600.0,"), (b'F', "0.0000"), (b'N', "50.0,0.0")]));
        for deg in [s.nav.target.unwrap().bearing_deg, s.player.heading_deg, s.nav.bearing_deg] {
            assert_eq!(format!("{:03.0}", deg.unwrap()), "000");
        }
        assert_eq!(compass_deg(-0.01), 0.0);
        assert_eq!(compass_deg(359.94), 359.9);
    }

    #[test]
    fn turns_left_are_negative() {
        assert_eq!(parse(&fields(&[(b'A', "0.5236")])).nav.turn_deg, Some(-30.0));
        assert_eq!(parse(&fields(&[(b'A', "3.1416")])).nav.turn_deg, Some(180.0));
    }
}
