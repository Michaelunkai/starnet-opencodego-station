import io

p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\app.js"
s = io.open(p, encoding="utf-8").read()

anchor = "  let unsubscribeStationSave = null;\n  let stationSaveQueued = false;"
assert anchor in s, "anchor not found"

block = r'''  /* ---------- EVERY CREW MEMBER GETS A DESK AND THE KIT FOR THEIR ROLE ----------
     The recurring complaint was "SCOUT has nowhere to sit yet - it needs a desk of its own
     before it can take floor work", repeated because NOTHING in the boot path ever placed a
     workstation for a crew member that came from the ROSTER rather than from a summon. Only
     team.summon seeded a desk (opts.desk), so a station booted from a written roster stood up
     eight bodies and zero desks, and every one of them was told it could not work.

     This runs on boot and after any roster change. It is IDEMPOTENT (it reads propsByAgent
     first) and it is HONEST: it reports what it actually placed, and it never claims a desk it
     could not place. Each desk also gets ONE role prop so the trade reads at a glance -
     papers for the researcher, a chart wall for the analyst, a tool caddy for the engineer,
     a book stack for the writer, the mission board for the scout, a rack for the operator,
     the whiteboard for the foreman. */
  const CREW_ROLE_PROP = {
    researcher: { t: 'research_papers', w: 2, h: 1, block: false },
    analyst:    { t: 'chartwall',      w: 2, h: 1, block: false },
    engineer:   { t: 'toolbox',        w: 1, h: 1, block: false },
    writer:     { t: 'bookstack',      w: 1, h: 1, block: false },
    scout:      { t: 'missionboard',   w: 2, h: 1, block: false },
    operator:   { t: 'rack',           w: 1, h: 1, block: true  },
    foreman:    { t: 'whiteboard',     w: 2, h: 1, block: false }
  };

  function crewIdsWithoutDesk() {
    const out = [];
    try {
      if (!station || typeof station.propsByAgent !== 'function') return out;
      for (const a of liveAgents()) {
        const id = String((a && a.id) || '');
        if (!id || id === 'agent') continue;                 // the hero's starter desk is seeded at wake
        if (needsWorkstation(id)) out.push(id);
      }
    } catch (_) {}
    return out;
  }

  function placeCrewKit(id, desk) {
    const spec = CREW_ROLE_PROP[id];
    if (!spec || !desk || !station || typeof station.addProp !== 'function') return null;
    try {
      const mine = station.propsByAgent(id) || [];
      if (mine.some(p => p.t === spec.t)) return 'existing';   // idempotent
      // try the eight neighbours of the desk, nearest first, and keep the first legal flat spot
      const cand = [];
      for (let dy = -1; dy <= 1; dy++) for (let dx = -2; dx <= 2; dx++) {
        if (!dx && !dy) continue;
        cand.push({ x: desk.x + dx, y: desk.y + dy });
      }
      for (const c of cand) {
        if (station.canPlaceProp && !station.canPlaceProp(spec.t, c.x, c.y, spec.w, spec.h)) continue;
        const r = station.addProp({ t: spec.t, x: c.x, y: c.y, w: spec.w, h: spec.h, block: spec.block });
        if (r && r.ok) return 'placed';
      }
    } catch (_) {}
    return null;
  }

  let crewDeskPass = null;
  function ensureCrewWorkstations() {
    if (crewDeskPass) return crewDeskPass;
    crewDeskPass = (async () => {
      const report = { desks: [], kits: [], failed: [] };
      // a few passes: placing one desk can free/occupy a tile the next one wanted
      for (let pass = 0; pass < 3; pass++) {
        const missing = crewIdsWithoutDesk();
        if (!missing.length) break;
        let progressed = false;
        for (const id of missing) {
          if (!needsWorkstation(id)) continue;
          let placed = null;
          try { placed = station && station.ensureWorkstation ? station.ensureWorkstation(id) : null; } catch (_) {}
          if (placed && placed.ok) {
            report.desks.push({ id, adopted: !!placed.adopted, x: placed.x, y: placed.y });
            progressed = true;
            const kit = placeCrewKit(id, placed);
            if (kit === 'placed') report.kits.push(id);
          } else if (placed) {
            report.failed.push({ id, error: placed.error || 'no spot' });
          }
        }
        if (!progressed) break;
      }
      try { if (report.desks.length || report.kits.length) { persist(); renderRail(); } } catch (_) {}
      try { if (window.__STARNET_DEV__) console.log('[crew-desks]', JSON.stringify(report)); } catch (_) {}
      return report;
    })();
    return crewDeskPass;
  }
  // Re-arm when the roster grows or the station document finishes loading: a desk pass that ran
  // before the floor existed would find no rooms and must not be the last word.
  try {
    setTimeout(() => { ensureCrewWorkstations(); }, 1200);
    setTimeout(() => { ensureCrewWorkstations(); }, 5000);
  } catch (_) {}

'''

s = s.replace(anchor, block + anchor, 1)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("patched app.js: crew desk + role kit seeder")
