/* Turns parsed card data into the 7 rows of a Sunday–Saturday timesheet (local UK time). */
(function (root) {
  'use strict';
  const Tacho = root.Tacho || (typeof require !== 'undefined' ? require('./tacho.js') : null);

  const TZ = 'Europe/London';
  const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MIN = 60000, HOUR = 3600000, DAY = 86400000;
  const dtf = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', weekday: 'short',
  });

  function local(ms) {
    const o = {};
    for (const p of dtf.formatToParts(new Date(ms))) o[p.type] = p.value;
    return { y: +o.year, m: +o.month, d: +o.day, hh: o.hour, mm: o.minute, dow: DOW.indexOf(o.weekday), time: o.hour + ':' + o.minute };
  }
  // Calendar dates are handled as "YYYY-MM-DD" keys; arithmetic is done on UTC midnights.
  const keyOf = (y, m, d) => new Date(Date.UTC(y, m - 1, d)).toISOString().slice(0, 10);
  const addDays = (key, n) => new Date(Date.parse(key) + n * DAY).toISOString().slice(0, 10);
  const localKey = (ms) => { const l = local(ms); return keyOf(l.y, l.m, l.d); };
  const sundayOf = (ms) => { const l = local(ms); return keyOf(l.y, l.m, l.d - l.dow); };
  const dayDiff = (a, b) => Math.round((Date.parse(b) - Date.parse(a)) / DAY);

  function distKm(a, b) {
    const R = 6371, r = Math.PI / 180;
    const dLat = (b.lat - a.lat) * r, dLon = (b.lon - a.lon) * r;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(dLon / 2) ** 2;
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  const hm = (min) => Math.floor(min / 60) + ':' + String(Math.round(min % 60)).padStart(2, '0');

  // Every GNSS fix on the card, for "where was the truck around time t" lookups.
  function allFixes(card) {
    const out = [];
    for (const p of card.places) if (p.gnss) out.push({ t: +p.time, pos: p.gnss, country: p.country, src: 'place' });
    for (const g of card.gnssPlaces) if (g.gnss) out.push({ t: +g.time, pos: g.gnss, src: '3h' });
    for (const l of card.loadUnload) if (l.gnss) out.push({ t: +l.time, pos: l.gnss, src: 'load' });
    for (const b of card.borders) out.push({ t: +b.time, pos: b.gnss, country: b.entered, src: 'border' });
    return out.sort((a, b) => a.t - b.t);
  }

  function prepare(card, opts = {}) {
    const shifts = Tacho.buildShifts(card.segments, opts.minRestMin || 420);
    const fixes = allFixes(card);
    const near = (t, before, after) => {
      let best = null;
      for (const f of fixes) if (f.t >= t - before && f.t <= t + after && (!best || Math.abs(f.t - t) < Math.abs(best.t - t))) best = f;
      return best;
    };
    shifts.forEach((sh, i) => {
      const start = sh.cardIn || sh.start;
      sh.restBefore = i > 0 ? start - shifts[i - 1].end : Infinity;
      sh.restAfter = i + 1 < shifts.length ? (shifts[i + 1].cardIn || shifts[i + 1].start) - sh.end : Infinity;
      const b = card.places.find((p) => p.begin && p.gnss && Math.abs(p.time - start) <= 45 * MIN);
      const e = card.places.find((p) => !p.begin && p.gnss && Math.abs(p.time - sh.end) <= 45 * MIN);
      sh.startFix = b ? { pos: b.gnss, country: b.country, src: 'place' } : null;
      sh.endFix = e ? { pos: e.gnss, country: e.country, src: 'place' } : near(sh.end, 45 * MIN, 5 * MIN);
      sh.lastFix = sh.endFix || [...fixes].reverse().find((f) => f.t <= sh.end && f.t >= start) || null;
    });
    // "exact" = a begin/end place record, or a fix within 5 minutes; anything else is only a hint.
    const ex = (f, t) => f.src === 'place' || (f.t !== undefined && Math.abs(f.t - t) <= 5 * MIN);
    shifts.forEach((sh) => {
      if (sh.startFix) sh.startFix = { ...sh.startFix, exact: ex(sh.startFix, sh.cardIn || sh.start) };
      if (sh.endFix) sh.endFix = { ...sh.endFix, exact: ex(sh.endFix, sh.end) };
    });
    shifts.forEach((sh, i) => {   // truck usually hasn't moved overnight
      if (!sh.startFix && i > 0 && sh.restBefore < 20 * HOUR && shifts[i - 1].endFix) sh.startFix = { ...shifts[i - 1].endFix, src: 'prev' };
      if (!sh.startFix) {
        const f = near(sh.cardIn || sh.start, 5 * MIN, 45 * MIN);
        if (f) sh.startFix = { ...f, exact: ex(f, sh.cardIn || sh.start) };
      }
    });
    return { shifts, fixes };
  }

  // Home base = where weekly rests (24h+) are taken, unless the user set one.
  function guessBase(prep) {
    const pts = prep.shifts.filter((s) => s.restAfter >= 24 * HOUR && s.restAfter !== Infinity && s.endFix).map((s) => s.endFix.pos);
    let best = null, bestN = 0;
    for (const p of pts) { const n = pts.filter((q) => distKm(p, q) < 2).length; if (n > bestN) { best = p; bestN = n; } }
    return best ? { lat: best.lat, lon: best.lon, count: bestN } : null;
  }

  function listWeeks(prep) {
    const set = new Set(prep.shifts.map((s) => sundayOf(s.cardIn || s.start)));
    return [...set].sort().reverse();
  }

  // Stops between "real" drives (driving ≥ 4 min); shows the driver where the drops probably were.
  function stopsOf(sh) {
    const drives = sh.segs.filter((s) => s.activity === 3 && s.end - s.start >= 4 * MIN);
    const stops = [];
    for (let i = 0; i + 1 < drives.length; i++) {
      const a = drives[i].end, b = drives[i + 1].start;
      if (b - a < 10 * MIN) continue;
      let work = 0, rest = 0;
      for (const s of sh.segs) {
        const o = Math.max(0, Math.min(b, s.end) - Math.max(a, s.start)) / MIN;
        if (!o) continue;
        if (s.activity === 2 || s.activity === 1) work += o; else if (s.activity === 0) rest += o;
      }
      // Pure breaks (no work) are not drops.
      if (work >= 5) stops.push({ from: a, to: b, work: Math.round(work), rest: Math.round(rest), label: local(a).time + '–' + local(b).time });
    }
    return stops;
  }

  function computeWeek(card, prep, sundayKey, opts = {}) {
    const base = opts.base || null, awayKm = opts.awayKm || 25;
    const rows = Array.from({ length: 7 }, (_, i) => ({ date: addDays(sundayKey, i), shifts: [], drops: [], stops: [] }));
    for (const sh of prep.shifts) {
      const idx = dayDiff(sundayKey, localKey(sh.cardIn || sh.start));
      if (idx >= 0 && idx < 7) rows[idx].shifts.push(sh);
    }
    for (const r of rows) {
      if (!r.shifts.length) continue;
      const first = r.shifts[0], last = r.shifts[r.shifts.length - 1];
      r.start = first.cardIn || first.start; r.end = last.end;
      r.startTime = local(r.start).time; r.finishTime = local(r.end).time;
      if (localKey(r.end) !== r.date) r.finishNote = 'next day';
      r.startFix = first.startFix; r.endFix = last.endFix;
      r.drivingMin = r.shifts.reduce((a, s) => a + s.driving, 0);
      r.driving = hm(r.drivingMin);
      r.workMin = r.shifts.reduce((a, s) => a + s.work + s.availability, 0);
      r.drops = card.loadUnload.filter((l) => l.time >= r.start - 10 * MIN && l.time <= r.end + 10 * MIN)
        .map((l) => ({ time: +l.time, op: l.op, opName: l.opName, pos: l.gnss }));
      r.stops = r.shifts.flatMap(stopsOf);
      // Night out: the day ends away from base, and it isn't the start of a weekly rest at home.
      const endPos = (last.endFix || last.lastFix || {}).pos;
      const away = base && endPos ? distKm(base, endPos) > awayKm : null;
      // An exact end-of-day place decides it; a rough position only counts if no weekly rest follows.
      const exact = last.endFix && last.endFix.src === 'place';
      r.nightOut = (exact ? away : last.restAfter < 24 * HOUR && away !== false) ? 'UK' : '';
      const ctry = (last.endFix && last.endFix.country) || '';
      if (r.nightOut && ctry && ctry !== 'UK') r.nightOut = 'EU';
    }
    // Vehicle(s), most used first.
    const ws = Date.parse(sundayKey) - 2 * HOUR, we = ws + 7 * DAY + 4 * HOUR, use = {};
    for (const v of card.vehicles) {
      const a = Math.max(ws, +v.firstUse), b = Math.min(we, +(v.lastUse || v.firstUse));
      if (b > a) use[v.reg] = (use[v.reg] || 0) + (b - a);
    }
    const vehicle = Object.keys(use).sort((a, b) => use[b] - use[a]).join(' / ');
    return { sunday: sundayKey, saturday: addDays(sundayKey, 6), rows, vehicle };
  }

  const api = { prepare, guessBase, listWeeks, computeWeek, local, localKey, sundayOf, addDays, distKm, hm, DOW };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.Week = api;
})(typeof self !== 'undefined' ? self : globalThis);
