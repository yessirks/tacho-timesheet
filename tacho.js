/* Driver card (.ddd / .c1b / .esm) parser — EU Regulation 165/2014, Annex 1B / 1C.
 * Handles Gen1, Gen2 and Gen2v2 ("smart tachograph 2") card downloads.
 * Everything is returned in UTC; the UI converts to local (Europe/London) time. */
(function (root) {
  'use strict';

  const ACT = ['Break/Rest', 'Availability', 'Work', 'Driving'];

  const NATIONS = ['', 'A', 'AL', 'AND', 'ARM', 'AZ', 'B', 'BG', 'BIH', 'BY', 'CH', 'CY', 'CZ', 'D', 'DK', 'E',
    'EST', 'F', 'FIN', 'FL', 'FO', 'UK', 'GE', 'GR', 'H', 'HR', 'I', 'IRL', 'IS', 'KZ', 'L', 'LT', 'LV', 'M', 'MC',
    'MD', 'MK', 'N', 'NL', 'P', 'PL', 'RO', 'RSM', 'RUS', 'S', 'SK', 'SLO', 'TM', 'TR', 'UA', 'V', 'YU', 'MNE',
    'SRB', 'UZ', 'TJ', 'KG'];
  const nation = (n) => n === 0xFD ? 'EC' : n === 0xFE ? 'EUR' : n === 0xFF ? 'WLD' : (NATIONS[n] || ('#' + n));

  const PLACE_ENTRY = ['Begin', 'End', 'Begin (manual)', 'End (manual)', 'Begin (assumed)', 'End (assumed)'];
  const LOAD_OP = ['', 'Load', 'Unload', 'Load+Unload'];

  // ---- byte helpers -------------------------------------------------------
  const u8 = (b, o) => b[o];
  const u16 = (b, o) => (b[o] << 8) | b[o + 1];
  const u24 = (b, o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
  const u32 = (b, o) => ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];
  const s24 = (b, o) => { const v = u24(b, o); return v & 0x800000 ? v - 0x1000000 : v; };
  const time = (b, o) => { const t = u32(b, o); return t === 0 || t === 0xFFFFFFFF ? null : new Date(t * 1000); };
  const bcd = (b, o, n) => { let s = ''; for (let i = 0; i < n; i++) s += (b[o + i] >> 4) + '' + (b[o + i] & 15); return s; };

  function str(b, o, n, hasCodepage) {
    // Strings are ISO-8859-x; we only need Latin letters, so decode as latin1.
    let s = '';
    for (let i = hasCodepage ? 1 : 0; i < n; i++) { const c = b[o + i]; if (c) s += String.fromCharCode(c); }
    return s.replace(/\s+$/, '').replace(/^\s+/, '');
  }

  // GNSS coordinates are ±DDMM.M × 10 (so 51450 = 51° 45.0').
  function coord(v) {
    if (v === 0x7FFFFF || v === -0x7FFFFF || v === 0x800000) return null;
    const a = Math.abs(v), deg = Math.floor(a / 1000), min = (a % 1000) / 10;
    return (v < 0 ? -1 : 1) * (deg + min / 60);
  }
  function gnss(b, o) { // GNSSPlaceRecord: timeStamp(4) accuracy(1) lat(3) lon(3)
    const lat = coord(s24(b, o + 5)), lon = coord(s24(b, o + 8));
    if (lat === null || lon === null || (lat === 0 && lon === 0) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
    return { time: time(b, o), accuracy: u8(b, o + 4), lat, lon };
  }

  // ---- container ----------------------------------------------------------
  // The .ddd is a list of: fileId(2) type(1) length(2) data.  type 0/1 = Gen1 data/signature, 2/3 = Gen2.
  function splitFiles(buf) {
    const files = {}; let o = 0;
    while (o + 5 <= buf.length) {
      const fid = u16(buf, o), type = buf[o + 2], len = u16(buf, o + 3);
      if (o + 5 + len > buf.length) break;
      const gen = type >= 2 ? 2 : 1;
      if (type % 2 === 0) files[fid.toString(16).toUpperCase().padStart(4, '0') + '_' + gen] = buf.subarray(o + 5, o + 5 + len);
      o += 5 + len;
    }
    return files;
  }

  // ---- individual files ---------------------------------------------------
  function parseIdentification(b) {
    return {
      issuingNation: nation(b[0]),
      cardNumber: str(b, 1, 16, false),
      issuingAuthority: str(b, 17, 36, true),
      issueDate: time(b, 53), validFrom: time(b, 57), expiry: time(b, 61),
      surname: str(b, 65, 36, true),
      firstNames: str(b, 101, 36, true),
      birthDate: bcd(b, 137, 4),
      language: str(b, 141, 2, false),
    };
  }

  function parseActivity(b) {
    // CardDriverActivity: oldestDayPtr(2) newestRecordPtr(2) then a cyclic buffer of daily records.
    const oldest = u16(b, 0), newest = u16(b, 2), ring = b.subarray(4), n = ring.length;
    const rd = (pos, len) => { const out = new Uint8Array(len); for (let i = 0; i < len; i++) out[i] = ring[(pos + i) % n]; return out; };
    const days = []; let pos = newest, guard = 0;
    while (guard++ < 2000) {
      const head = rd(pos, 12);
      const prevLen = u16(head, 0), len = u16(head, 2);
      if (len < 12 || len > n) break;
      const rec = rd(pos, len), date = time(rec, 4);
      if (!date) break;
      const changes = [];
      for (let i = 12; i + 1 < len; i += 2) {
        const v = u16(rec, i);
        changes.push({
          slot: v >> 15,              // 0 driver, 1 co-driver
          crew: (v >> 14) & 1,
          cardOut: (v >> 13) & 1,     // 1 = card not inserted
          activity: (v >> 11) & 3,    // 0 rest, 1 availability, 2 work, 3 driving
          minute: v & 0x7FF,          // minutes since 00:00 UTC
        });
      }
      days.push({ date, presence: bcd(rec, 8, 2), distance: u16(rec, 10), changes });
      if (pos === oldest || prevLen === 0) break;
      pos = (pos - prevLen + n) % n;
    }
    return days.reverse();
  }

  function parseVehicles(b, gen) {
    const size = gen === 2 ? 48 : 31, out = [];
    for (let o = 2; o + size <= b.length; o += size) {
      const first = time(b, o + 6), last = time(b, o + 10);
      if (!first) continue;
      out.push({
        odoBegin: u24(b, o), odoEnd: u24(b, o + 3), firstUse: first, lastUse: last,
        nation: nation(b[o + 14]), reg: str(b, o + 15, 14, true),
        vin: gen === 2 ? str(b, o + 31, 17, false) : '',
      });
    }
    return out.sort((a, c) => a.firstUse - c.firstUse);
  }

  function parsePlaces(b, gen) {
    const hdr = gen === 2 ? 2 : 1, size = gen === 2 ? 21 : 10, out = [];
    for (let o = hdr; o + size <= b.length; o += size) {
      const t = time(b, o);
      if (!t) continue;
      out.push({
        time: t, type: b[o + 4], typeName: PLACE_ENTRY[b[o + 4]] || ('#' + b[o + 4]),
        begin: b[o + 4] % 2 === 0, country: nation(b[o + 5]), region: b[o + 6], odo: u24(b, o + 7),
        gnss: gen === 2 ? gnss(b, o + 10) : null,
      });
    }
    return out.sort((a, c) => a.time - c.time);
  }

  function parseGnssPlaces(b) { // GNSSAccumulatedDrivingRecord: time(4) gnssPlace(11) odo(3) — every 3h of driving
    const out = [];
    for (let o = 2; o + 18 <= b.length; o += 18) {
      const t = time(b, o); if (!t) continue;
      out.push({ time: t, gnss: gnss(b, o + 4), odo: u24(b, o + 15) });
    }
    return out.sort((a, c) => a.time - c.time);
  }

  function parseBorders(b) { // countryLeft(1) countryEntered(1) gnssAuth(12) odo(3)
    const out = [];
    for (let o = 2; o + 17 <= b.length; o += 17) {
      const g = gnss(b, o + 2); if (!g || !g.time) continue;
      out.push({ time: g.time, left: nation(b[o]), entered: nation(b[o + 1]), gnss: g, odo: u24(b, o + 14) });
    }
    return out.sort((a, c) => a.time - c.time);
  }

  function parseLoadUnload(b) { // time(4) opType(1) gnssAuth(12) odo(3)
    const out = [];
    for (let o = 2; o + 20 <= b.length; o += 20) {
      const t = time(b, o); if (!t) continue;
      out.push({ time: t, op: b[o + 4], opName: LOAD_OP[b[o + 4]] || '?', gnss: gnss(b, o + 5), odo: u24(b, o + 17) });
    }
    return out.sort((a, c) => a.time - c.time);
  }

  // ---- timeline -----------------------------------------------------------
  // Flatten daily records into continuous segments [{start,end,activity,cardOut}] in UTC ms.
  function buildSegments(days) {
    const segs = [];
    for (const d of days) {
      const base = d.date.getTime();
      const ch = d.changes;
      for (let i = 0; i < ch.length; i++) {
        const s = base + ch[i].minute * 60000;
        const e = i + 1 < ch.length ? base + ch[i + 1].minute * 60000 : base + 1440 * 60000;
        if (e <= s) continue;
        const last = segs[segs.length - 1];
        const a = ch[i].activity, out = ch[i].cardOut;
        if (last && last.end === s && last.activity === a && last.cardOut === out) last.end = e;
        else segs.push({ start: s, end: e, activity: a, cardOut: out, slot: ch[i].slot });
      }
    }
    return segs;
  }

  // A shift (duty period) ends when the driver has a rest/no-card gap of at least `minRestMin`.
  function buildShifts(segs, minRestMin) {
    const minRest = (minRestMin || 420) * 60000, shifts = [];
    let cur = null, restStart = null, cardInAt = null, prev = null;
    const isRest = (s) => s.activity === 0 || s.cardOut;
    for (const s of segs) {
      if (prev && prev.cardOut && !s.cardOut) cardInAt = s.start;   // card inserted
      prev = s;
      if (isRest(s)) { if (restStart === null) restStart = s.start; continue; }
      if (cur && restStart !== null && s.start - restStart >= minRest) { shifts.push(cur); cur = null; }
      if (!cur) {
        // The working day starts when the card goes in (drivers copy this time from the tacho),
        // as long as that was shortly before the first activity.
        const cardIn = cardInAt !== null && cardInAt <= s.start && s.start - cardInAt <= 3600000 ? cardInAt : s.start;
        cur = { start: s.start, cardIn, end: s.end, segs: [] };
      }
      cur.end = s.end; cur.segs.push(s); restStart = null;
    }
    if (cur) shifts.push(cur);
    for (const sh of shifts) {
      const tot = [0, 0, 0, 0];
      for (const s of sh.segs) tot[s.activity] += (s.end - s.start) / 60000;
      sh.driving = tot[3]; sh.work = tot[2]; sh.availability = tot[1];
      // breaks inside the shift = span − active time
      sh.breaks = (sh.end - sh.start) / 60000 - tot[1] - tot[2] - tot[3];
    }
    return shifts;
  }

  function parse(buffer) {
    const buf = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
    const f = splitFiles(buf);
    const pick = (id) => f[id + '_2'] ? [f[id + '_2'], 2] : f[id + '_1'] ? [f[id + '_1'], 1] : [null, 0];
    const [idB] = pick('0520');
    if (!idB) throw new Error('This does not look like a driver card download (no identification block).');
    const [actB] = pick('0504'), [vehB, vehGen] = pick('0505'), [plB, plGen] = pick('0506');
    const dl = pick('050E')[0];
    const out = {
      generation: f['0501_2'] ? (f['0529_2'] ? '2v2' : '2') : '1',
      identification: parseIdentification(idB),
      lastDownload: dl ? time(dl, 0) : null,
      days: actB ? parseActivity(actB) : [],
      vehicles: vehB ? parseVehicles(vehB, vehGen) : [],
      places: plB ? parsePlaces(plB, plGen) : [],
      gnssPlaces: f['0524_2'] ? parseGnssPlaces(f['0524_2']) : [],
      borders: f['0528_2'] ? parseBorders(f['0528_2']) : [],
      loadUnload: f['0529_2'] ? parseLoadUnload(f['0529_2']) : [],
    };
    out.segments = buildSegments(out.days);
    return out;
  }

  const api = { parse, buildShifts, ACT, nation };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.Tacho = api;
})(typeof self !== 'undefined' ? self : this);
