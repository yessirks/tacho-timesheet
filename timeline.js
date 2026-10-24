/* Google Maps Timeline exports -> a flat list of visits { s, e, lat, lon, n, a } (times in ms).
 * Understands:
 *  - the on-phone export (2024+): Timeline.json with "semanticSegments" (Android), or a top-level array (iPhone)
 *  - Google Takeout "Semantic Location History" monthly files with "timelineObjects" */
(function (root) {
  'use strict';

  const ok = (lat, lon) => isFinite(lat) && isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);
  // "50.4361°, -3.5699°" | "geo:50.4361,-3.5699" | { latLng: "…" } | { latitudeE7, longitudeE7 }
  function point(v) {
    if (!v) return null;
    if (typeof v === 'object') {
      if ('latitudeE7' in v) return ok(v.latitudeE7 / 1e7, v.longitudeE7 / 1e7) ? { lat: v.latitudeE7 / 1e7, lon: v.longitudeE7 / 1e7 } : null;
      return point(v.latLng || v.point || v.location);
    }
    const m = String(v).match(/(-?\d+(?:\.\d+)?)\s*°?\s*,\s*(-?\d+(?:\.\d+)?)/);
    return m && ok(+m[1], +m[2]) ? { lat: +m[1], lon: +m[2] } : null;
  }
  const ms = (t) => { const v = Date.parse(t); return isFinite(v) ? v : null; };

  function fromSegments(list) {
    const out = [];
    for (const seg of list || []) {
      const v = seg && seg.visit;
      if (!v) continue;
      const c = v.topCandidate || {};
      const p = point(c.placeLocation);
      const s = ms(seg.startTime), e = ms(seg.endTime);
      if (!p || !s || !e) continue;
      out.push({ s, e, lat: p.lat, lon: p.lon, n: '', a: '', id: c.placeId || c.placeID || '', t: String(c.semanticType || '').toLowerCase() });
    }
    return out;
  }
  function fromTakeout(list) {
    const out = [];
    for (const o of list || []) {
      const v = o && o.placeVisit;
      if (!v) continue;
      const loc = v.location || {}, p = point(loc);
      const d = v.duration || {};
      const s = ms(d.startTimestamp || d.startTimestampMs && +d.startTimestampMs), e = ms(d.endTimestamp || d.endTimestampMs && +d.endTimestampMs);
      if (!p || !s || !e) continue;
      out.push({ s, e, lat: p.lat, lon: p.lon, n: loc.name || '', a: loc.address || '', id: loc.placeId || '', t: String(loc.semanticType || '').toLowerCase() });
    }
    return out;
  }
  // One file's text -> visits.
  function parse(text) {
    let j;
    try { j = JSON.parse(text); } catch { throw new Error('That file isn\'t a Google Timeline export (not JSON).'); }
    if (Array.isArray(j)) return j.some((x) => x && x.placeVisit) ? fromTakeout(j) : fromSegments(j);
    if (j.semanticSegments) return fromSegments(j.semanticSegments);
    if (j.timelineObjects) return fromTakeout(j.timelineObjects);
    if (j.locations) throw new Error('That\'s raw location points (Records.json). Use the Timeline export or the "Semantic Location History" files instead.');
    throw new Error('No Timeline visits found in that file.');
  }
  // Merge new visits into what we already have (same start and nearly the same spot = same visit).
  function merge(old, add) {
    const key = (v) => `${Math.round(v.s / 60000)}|${v.lat.toFixed(3)}|${v.lon.toFixed(3)}`;
    const map = new Map(old.map((v) => [key(v), v]));
    let added = 0;
    for (const v of add) { const k = key(v); if (!map.has(k)) { map.set(k, v); added++; } else if (v.n && !map.get(k).n) map.set(k, v); }
    return { list: [...map.values()].sort((a, b) => a.s - b.s), added };
  }

  root.Timeline = { parse, merge };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.Timeline;
})(typeof self !== 'undefined' ? self : globalThis);
