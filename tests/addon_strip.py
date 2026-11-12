"""End to end: run the real PolestarLink.lua against a stand-in game and a
stand-in Polestar, paint what it draws into a PNG, and read that back with the
real polestar-plus binary.

    cargo build --release
    python tests/addon_strip.py

Needs Python with lupa (Lua 5.1, the game's Lua).
"""

import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "PolestarLink" / "PolestarLink.lua"
# POLESTAR_PLUS_BIN picks another build, say the debug one while the release one is running.
BINARY = Path(os.environ.get("POLESTAR_PLUS_BIN") or ROOT / "target" / "release" / "polestar-plus.exe")

GAME = r"""
__textures, __hooks, __said = {}, {}, {}
__secret = {}
function issecretvalue(v) return v == __secret end
local function texture()
    local t = {}
    function t:SetPoint(_, x, y) self.x, self.y = x or 0, y or 0 end
    function t:SetSize(w, h) self.w, self.h = w, h end
    function t:SetAllPoints() self.all = true end
    function t:SetColorTexture(r, g, b) self.r, self.g, self.b = r, g, b end
    function t:SetSnapToPixelGrid() end
    function t:SetTexelSnappingBias() end
    __textures[#__textures + 1] = t
    return t
end
function CreateFrame()
    local f = { scripts = {}, events = {} }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:RegisterEvent(event)
        if event == "UI_SCALE_CHANGED" then error("unknown event") end
        self.events[event] = true
    end
    function f:CreateTexture() return texture() end
    function f:SetScale(s) self.scale = s end
    function f:ClearAllPoints() end
    function f:SetPoint() end
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:SetFrameStrata() end
    function f:SetFrameLevel() end
    function f:SetShown(on) self.shown = on end
    __frame = f
    return f
end
function GetPhysicalScreenSize() return 3440, 1440 end
function GetPlayerFacing() return 1.5708 end
function UnitName() return "Aldric", nil end
function UnitLevel() return 14 end
function GetZoneText() return "The Barrens" end
function GetSubZoneText() return "The Crossroads" end
function print(text) __said[#__said + 1] = text end
SlashCmdList = {}
"""

POLESTAR = r"""
local long = ...
local goals = {
    { t = "accept", status = "done", quest = 844, text = "Accept Plainstrider Menace" },
    { t = "kill", status = "active", quest = 844, text = "Kill |cffffd100Plainstriders|r", progress = { cur = 3, max = 7 },
      npcName = "Sergra Darkthorn", source = { name = "Greater Plainstrider", also = "Ornery Plainstrider", kind = "npc", enemy = true } },
    { t = "note", status = "na", text = "not for this character" },
    { t = "collect", status = "pending", text = "folded into another row", folded = true },
    { t = "turnin", status = "pending", quest = 844, text = "Turn in Plainstrider Menace" },
}
local note = "Sell junk first.|nThen head out."
if long then
    goals = {}
    for i = 1, 20 do
        goals[i] = { t = "kill", status = "active", quest = 900 + i, text = ("Kill something with a very long name %d "):format(i):rep(8) }
    end
    note = ("A very long note. "):rep(40)
end
Polestar = {
    version = "0.3.5",
    On = function(msg, fn) __hooks[msg] = fn end,
    Names = {},
    Engine = {
        GetGuide = function() return { id = "forever/horde/02-the-barrens", title = "The Barrens" } end,
        GetStepIndex = function() return 16 end,
        StepNumber = function() return 15, false end,
        StepTotal = function() return 160 end,
        GetLiveStep = function() return 16 end,
        GetProgress = function() return 40, 163 end,
        GetStepView = function() return { title = "The Crossroads", note = note, current = 2, goals = goals } end,
    },
    Nav = {
        Sample = function() return "travel", 312.4, -0.7854, 100, -100, true end,
        FloorHint = function() return nil end,
        GetTarget = function() return { label = "Plainstriders", kind = "kill", map = 1413, x = 52.23, y = 31.01 } end,
        GetTargetWorld = function() return 1, -100, -2600, 91.7 end,
        GetTargetZoneName = function() return "The Barrens" end,
        -- A flight still to come, then the walk being walked: from behind the
        -- player (at -400, -2600) north for 300 yd in one long stretch, then east.
        GetRouteGeometry = function()
            return { legs = {
                { kind = "flight", pts = { { 1, 0, 0 }, { 1, 900, 900 } } },
                { kind = "walk", current = true, pts = { { 1, -460.4, -2600 }, { 1, -420, -2600.2 }, { 1, -100, -2600 }, { 1, -100, -2650 } } },
            } }
        end,
    },
    Compat = {
        GetPlayerWorldPosition = function() return 1, -400, -2600 end,
        GetPlayerMapPosition = function() return 1413, __secret_position and __secret or 52.1, 30.05 end,
        GetQuestTitle = function(q) return q == 844 and "Plainstrider Menace" or error("no such quest") end,
    },
}
"""


def run_addon(long=False, polestar=True, secret_position=False, tweak=None):
    """Loads the add-on, logs in, lets it publish, and returns its cells."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(GAME)
    if polestar:
        lua.eval("function(src, long) return assert(loadstring(src))(long) end")(POLESTAR, long)
    if tweak:
        lua.execute(tweak)
    lua.globals().__secret_position = secret_position
    load = lua.eval("function(src) return assert(loadstring(src, 'PolestarLink.lua')) end")
    load(ADDON.read_text(encoding="utf-8"))("PolestarLink", lua.table())
    g = lua.globals()
    frame = g.__frame
    frame.scripts.OnEvent(frame, "ADDON_LOADED", "PolestarLink")
    frame.scripts.OnEvent(frame, "PLAYER_LOGIN")
    assert frame.shown is True, "the strip is shown after login"
    assert abs(frame.scale - 768 / 1440) < 1e-9, "one frame unit is one physical pixel"
    frame.scripts.OnUpdate(frame, 0.2)
    cells = [t for t in g.__textures.values() if not t.all]
    return lua, frame, cells


def paint(cells, to_byte, width=1600, height=64):
    """The strip over a noisy scene, as RGB rows."""
    rows = [bytearray(((x * 7 + y * 3) & 0xFF, (x + y * 11) & 0xFF, (x * 5) & 0xFF | 1)[c] for x in range(width) for c in range(3))
            for y in range(height)]
    for t in cells:
        x0, y0, w, h = int(t.x), int(-t.y), int(t.w), int(t.h)
        rgb = bytes(to_byte(v) for v in (t.r, t.g, t.b))
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                rows[y][x * 3:x * 3 + 3] = rgb
    return rows


def write_png(path, rows):
    width, height = len(rows[0]) // 3, len(rows)

    def part(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + part(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + part(b"IDAT", zlib.compress(raw)) + part(b"IEND", b""))


def read_back(cells, to_byte):
    with tempfile.TemporaryDirectory() as folder:
        png = Path(folder) / "strip.png"
        write_png(png, paint(cells, to_byte))
        out = subprocess.run([str(BINARY), "decode", str(png), "--json"], capture_output=True, text=True, encoding="utf-8")
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout)


# The client may round or truncate a colour to eight bits: both must read.
CONVERSIONS = {"rounding": lambda v: min(255, int(v * 255 + 0.5)), "truncating": lambda v: min(255, math.floor(v * 255))}


def main():
    if not BINARY.exists():
        sys.exit(f"build first: {BINARY} is missing")

    for name, to_byte in CONVERSIONS.items():
        _, _, cells = run_addon()
        assert len(cells) == 500 and max(t.x + t.w for t in cells) == 750 and max(-t.y + t.h for t in cells) == 6
        s = read_back(cells, to_byte)
        assert s["status"] == "ok", s
        assert s["polestar_version"] == s["polestar_tested"] == "0.3.5" and s["missing_calls"] == []
        assert s["player"]["name"] == "Aldric" and s["player"]["level"] == 14
        assert (s["player"]["zone"], s["player"]["subzone"]) == ("The Barrens", "The Crossroads")
        assert s["player"]["heading"] == "W" and s["player"]["map_x"] == 52.1
        assert s["guide"] == {"id": "forever/horde/02-the-barrens", "title": "The Barrens", "done": 40, "total": 163}
        assert s["step"]["number"] == 15 and s["step"]["total"] == 160 and s["step"]["title"] == "The Crossroads"
        assert s["step"]["note"] == "Sell junk first. Then head out."
        assert s["quest"] == {"id": 844, "title": "Plainstrider Menace"}
        assert [g["index"] for g in s["goals"]] == [1, 2, 5], "goals that do not apply or are folded are left out"
        kill = s["goals"][1]
        assert kill["text"] == "Kill Plainstriders" and kill["current"] and (kill["have"], kill["need"]) == (3, 7)
        assert kill["npc"] == "Sergra Darkthorn" and kill["source"]["also"] == "Ornery Plainstrider" and kill["source"]["enemy"]
        assert kill["needs"] == "at Sergra Darkthorn  ·  kill Greater Plainstrider or Ornery Plainstrider"
        assert s["goals"][0]["needs"] is None, "only the goal the arrow leads to says what it needs"
        nav = s["nav"]
        assert nav["state"] == "travel" and nav["along_path"] and nav["distance_yd"] == 312.4
        assert nav["bearing"] == "NE" and nav["turn_deg"] == 45.0
        assert nav["target"]["label"] == "Plainstriders" and nav["target"]["straight_yd"] == 300.0
        assert nav["target"]["world_height"] == 91.7 and nav["target"]["zone"] == "The Barrens"
        # The path is picked up one point before the player's nearest, and the
        # 320 yd stretch arrives as three steps a byte can hold.
        assert nav["route"]["continent"] == 1
        assert nav["route"]["points"] == [[-460, -2600], [-420, -2600], [-293, -2600], [-166, -2600], [-100, -2600], [-100, -2650]]
        print(f"ok  full snapshot, client {name} colours")

    # More text than the strip holds: whole fields are dropped, never cut.
    _, _, cells = run_addon(long=True)
    s = read_back(cells, CONVERSIONS["rounding"])
    assert s["status"] == "ok" and s["guide"]["id"] and s["nav"]["state"] == "travel"
    assert 1 <= len(s["goals"]) <= 12 and all(g["text"].startswith("Kill something") for g in s["goals"])
    print(f"ok  overfull step: {len(s['goals'])} goals kept, note {'kept' if s['step']['note'] else 'dropped'}")

    # A value the game keeps secret is left out, the rest still reads.
    _, _, cells = run_addon(secret_position=True)
    s = read_back(cells, CONVERSIONS["rounding"])
    assert s["player"]["map_x"] is None and s["player"]["world_north"] == -400.0 and s["status"] == "ok"
    print("ok  secret value left out")

    # A Polestar update that renamed things: the version and what is gone are
    # reported, and everything that still works still reads.
    _, _, cells = run_addon(tweak='Polestar.version = "0.4.0"; Polestar.Nav.Sample = nil; Polestar.Compat.GetQuestTitle = nil')
    s = read_back(cells, CONVERSIONS["rounding"])
    assert s["polestar_version"] == "0.4.0" and s["missing_calls"] == ["Nav.Sample", "Compat.GetQuestTitle"], s
    assert s["status"] == "ok" and s["nav"]["state"] == "" and s["step"]["title"] == "The Crossroads"
    assert s["nav"]["route"]["points"][0] == [-460, -2600], "the path still reads when other calls are gone"
    assert s["quest"] == {"id": 844, "title": None} and s["nav"]["target"]["label"] == "Plainstriders"
    _, _, cells = run_addon(tweak="Polestar.Engine = nil")
    s = read_back(cells, CONVERSIONS["rounding"])
    assert s["status"] == "no-engine" and s["missing_calls"] == ["Engine"] and s["nav"]["state"] == "travel", s
    print("ok  changed Polestar: version and missing calls reported")

    # Without Polestar the strip still says who and where, and why nothing else.
    _, _, cells = run_addon(polestar=False)
    s = read_back(cells, CONVERSIONS["rounding"])
    assert s["status"] == "no-polestar" and s["player"]["name"] == "Aldric" and s["guide"] is None
    print("ok  Polestar not loaded")

    # Polestar's step-changed message republishes on the next tick; /plk toggles.
    lua, frame, cells = run_addon()
    g = lua.globals()
    assert all(g.__hooks[m] for m in ("STEP_CHANGED", "GUIDE_CHANGED", "WAYPOINT_CHANGED"))
    g.SlashCmdList.POLESTARLINK("off")
    assert frame.shown is False
    g.SlashCmdList.POLESTARLINK("")
    assert frame.shown is True
    first = read_back(cells, CONVERSIONS["rounding"])
    frame.scripts.OnUpdate(frame, 0.2)
    assert read_back(cells, CONVERSIONS["rounding"]) == first, "a second publish of the same state reads the same"
    print("ok  hooks and /plk")


if __name__ == "__main__":
    main()
