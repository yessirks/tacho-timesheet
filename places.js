/* Location helpers: where am I, what's around me, reading Google Maps links,
 * navigation links, and GPX / KML / CSV import-export for starred places. */
(function (root) {
  'use strict';

  const R = 6371000;
  function distM(a, b) {
    const r = Math.PI / 180, dLat = (b.lat - a.lat) * r, dLon = (b.lon - a.lon) * r;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(dLon / 2) ** 2;
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  const fmtDist = (m) => (m < 1000 ? `${Math.round(m / 5) * 5 || 5} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`);
  const ok = (lat, lon) => isFinite(lat) && isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);

  // ---- where am I -----------------------------------------------------------------------------
  function here() {
    return new Promise((res, rej) => {
      if (!navigator.geolocation) return rej(new Error('This browser has no location access.'));
      navigator.geolocation.getCurrentPosition(
        (p) => res({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy }),
        (e) => rej(new Error(e.code === 1 ? 'Location is blocked. Allow location for this site in your browser settings.'
          : e.code === 3 ? 'Getting your location took too long. Try again outside or with GPS on.' : 'Could not get your location.')),
        { enableHighAccuracy: true, timeout: 20000, maximumAge: 15000 });
    });
  }

  // ---- what's around me (OpenStreetMap) ----------------------------------------------------------
  async function reverse(lat, lon) {
    const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat.toFixed(6)}&lon=${lon.toFixed(6)}&zoom=18&addressdetails=1&accept-language=en`);
    if (!r.ok) throw new Error('lookup failed');
    const j = await r.json(), a = j.address || {};
    return {
      town: a.town || a.village || a.city || a.suburb || a.hamlet || a.county || '',
      postcode: a.postcode || '', road: a.road || '', name: j.name || '', display: j.display_name || '',
    };
  }
  const OVERPASS = ['https://overpass-api.de/api/interpreter', 'https://overpass.private.coffee/api/interpreter', 'https://maps.mail.ru/osm/tools/overpass/api/interpreter'];
  const SKIP = ['parking', 'parking_entrance', 'bench', 'waste_basket', 'toilets', 'telephone', 'post_box', 'bicycle_parking', 'place_of_worship', 'house', 'residential', 'yes', 'grave_yard'];
  async function timed(url, opts, ms) {
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), ms);
    try { return await fetch(url, { ...opts, signal: ctl.signal }); } finally { clearTimeout(t); }
  }
  // Photon (komoot): fast, and returns the town with each place.
  async function photon(lat, lon, radius) {
    const tags = ['shop', 'amenity', 'landuse:industrial', 'landuse:commercial', 'landuse:retail', 'landuse:farmyard', 'industrial', 'building', 'man_made', 'office', 'craft', 'highway:services', 'highway:rest_area']
      .map((t) => '&osm_tag=' + encodeURIComponent(t)).join('');
    const r = await timed(`https://photon.komoot.io/reverse?lat=${lat}&lon=${lon}&limit=30&radius=${radius / 1000}&lang=en${tags}`, {}, 10000);
    if (!r.ok) throw new Error('photon ' + r.status);
    const j = await r.json();
    return (j.features || []).map((f) => {
      const p = f.properties || {}, [x, y] = f.geometry.coordinates;
      return { name: p.name, kind: p.osm_value || '', lat: y, lon: x, city: p.city || p.town || p.village || p.district || '' };
    });
  }
  // Overpass: the full map database; often busy, so it's the backup.
  async function overpass(lat, lon, radius) {
    const q = `[out:json][timeout:12];(
      nwr(around:${radius},${lat},${lon})[name][~"^(shop|amenity|industrial|office|craft|man_made|building|tourism|company)$"~"."];
      nwr(around:${radius},${lat},${lon})[name]["landuse"~"industrial|commercial|retail|farmyard"];
      nwr(around:${radius},${lat},${lon})[name]["highway"~"services|rest_area"];
    );out center tags 60;`;
    for (const url of OVERPASS) {
      try {
        const r = await timed(url, { method: 'POST', body: 'data=' + encodeURIComponent(q), headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }, 15000);
        if (!r.ok) continue;
        const j = await r.json();
        return (j.elements || []).map((el) => {
          const t = el.tags || {}, p = el.center || el;
          const name = t.brand && t.name && !t.name.toLowerCase().includes(t.brand.toLowerCase()) ? `${t.brand} ${t.name}` : t.name;
          return { name, kind: t.shop || t.amenity || t.industrial || t.office || t.craft || t.man_made || t.landuse || t.highway || t.tourism || t.building || '', lat: p.lat, lon: p.lon, city: t['addr:city'] || t['addr:town'] || '' };
        });
      } catch { /* next mirror */ }
    }
    throw new Error('The map server is busy.');
  }
  // Named places a lorry stops at, ranked: supermarkets, depots, factories and services first.
  async function nearby(lat, lon, radius = 300) {
    let raw;
    try { raw = await photon(lat, lon, radius); } catch { raw = await overpass(lat, lon, radius); }
    const seen = new Set(), out = [];
    for (const p of raw) {
      if (!p.name || !ok(p.lat, p.lon) || SKIP.includes(p.kind)) continue;
      const key = p.name.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ ...p, kind: p.kind.replace(/_/g, ' '), dist: distM({ lat, lon }, p) });
    }
    const trade = /supermarket|wholesale|warehouse|industrial|depot|factory|works|distribution|logistics|farm|dairy|services|fuel|cash.and.carry|doityourself|trade|retail|commercial|hardware|garden.centre|department.store|car.parts|builders/i;
    const rank = (p) => p.dist * (trade.test(p.kind) ? 0.5 : 1);
    return out.sort((a, b) => rank(a) - rank(b)).slice(0, 15);
  }

  // Search a name, address or postcode (UK), nearest to you first when we know where you are.
  async function search(q, near) {
    const bias = near ? `&lat=${near.lat}&lon=${near.lon}` : '';
    try {
      const r = await timed(`https://photon.komoot.io/api/?q=${encodeURIComponent(q)}&limit=8&lang=en&bbox=-8.7,49.8,2.0,60.9${bias}`, {}, 8000);
      if (r.ok) {
        const j = await r.json();
        const out = (j.features || []).map((f) => {
          const p = f.properties || {}, [x, y] = f.geometry.coordinates;
          return { name: p.name || [p.housenumber, p.street].filter(Boolean).join(' ') || p.postcode || '', city: p.city || p.town || p.village || '', sub: [p.street, p.city || p.town || p.village, p.postcode].filter(Boolean).join(', '), lat: y, lon: x };
        }).filter((r) => r.name);
        const seen = new Set(), uniq = out.filter((r) => { const k = (r.name + '|' + r.sub).toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; });
        if (uniq.length) return uniq;
      }
    } catch { /* try Nominatim */ }
    const r = await timed(`https://nominatim.openstreetmap.org/search?format=jsonv2&q=${encodeURIComponent(q)}&countrycodes=gb&limit=8`, {}, 8000);
    if (!r.ok) throw new Error('search failed');
    return (await r.json()).map((x) => ({ name: x.name || x.display_name.split(',')[0], sub: x.display_name.split(',').slice(1, 4).join(',').trim(), lat: +x.lat, lon: +x.lon }));
  }

  // ---- reading coordinates out of whatever you paste ---------------------------------------------
  function dms(str) {
    const m = str.match(/(\d+(?:\.\d+)?)\s*°\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*["″]\s*)?([NSEW])/gi);
    if (!m || m.length < 2) return null;
    const one = (s) => {
      const p = s.match(/(\d+(?:\.\d+)?)\s*°\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*["″]\s*)?([NSEW])/i);
      const v = +p[1] + (+p[2] || 0) / 60 + (+p[3] || 0) / 3600;
      return { v: /[SW]/i.test(p[4]) ? -v : v, ns: /[NS]/i.test(p[4]) };
    };
    const a = one(m[0]), b = one(m[1]);
    const lat = a.ns ? a.v : b.v, lon = a.ns ? b.v : a.v;
    return ok(lat, lon) ? { lat, lon } : null;
  }
  // Google Maps links (long ones), "lat, lon", geo: URIs, Apple/Waze/OSM links, degrees-minutes-seconds.
  function parseCoords(text) {
    if (!text) return null;
    const s = String(text).trim();
    let name = '';
    try { const m = s.match(/\/place\/([^/@?]+)/); if (m) name = decodeURIComponent(m[1].replace(/\+/g, ' ')); } catch { /* ignore */ }
    const pats = [
      /!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/,                     // the pin itself in a Google place link
      /[?&](?:q|query|ll|destination|daddr|sll|center)=(-?\d+(?:\.\d+)?)(?:,|%2C)\s*(-?\d+(?:\.\d+)?)/i,
      /@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/,                          // map centre
      /geo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/i,
      /[?&]mlat=(-?\d+(?:\.\d+)?)&mlon=(-?\d+(?:\.\d+)?)/,
      /^\s*(-?\d{1,2}\.\d+)\s*[,;\s]\s*(-?\d{1,3}\.\d+)\s*$/,          // "50.4434, -4.6394"
      /(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})/,
    ];
    for (const p of pats) {
      const m = s.match(p);
      if (m && ok(+m[1], +m[2])) return { lat: +m[1], lon: +m[2], name };
    }
    const d = dms(s);
    if (d) return { ...d, name };
    return null;
  }
  const isShortLink = (s) => /(maps\.app\.goo\.gl|goo\.gl\/maps|g\.co\/kgs)/i.test(s || '');

  // ---- navigation ---------------------------------------------------------------------------------
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  const isIOS = /iPhone|iPad|iPod/i.test(ua), isAndroid = /Android/i.test(ua);
  function navLinks(p) {
    const ll = `${p.lat.toFixed(6)},${p.lon.toFixed(6)}`;
    return {
      google: `https://www.google.com/maps/dir/?api=1&destination=${ll}&travelmode=driving`,
      waze: `https://waze.com/ul?ll=${ll}&navigate=yes`,
      // TomTom GO: its own link on iPhone; on Android the geo: link lets you pick TomTom (or any sat-nav app).
      tomtom: isIOS ? `tomtomgo://x-callback-url/navigate?destination=${ll}` : isAndroid ? `geo:${ll}?q=${ll}(${encodeURIComponent(p.name || 'Destination')})` : '',
      view: `https://www.google.com/maps/search/?api=1&query=${ll}`,
      ll,
    };
  }

  // ---- export / import ------------------------------------------------------------------------------
  const x = (s) => String(s ?? '').replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]));
  function toGPX(list) {
    return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Trukia" xmlns="http://www.topografix.com/GPX/1/1">\n` +
      list.map((p) => `  <wpt lat="${p.lat.toFixed(6)}" lon="${p.lon.toFixed(6)}"><name>${x(p.name)}</name>${p.note ? `<desc>${x(p.note)}</desc>` : ''}</wpt>`).join('\n') + '\n</gpx>\n';
  }
  function toKML(list) {
    return `<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Starred places</name>\n` +
      list.map((p) => `<Placemark><name>${x(p.name)}</name>${p.note ? `<description>${x(p.note)}</description>` : ''}<Point><coordinates>${p.lon.toFixed(6)},${p.lat.toFixed(6)},0</coordinates></Point></Placemark>`).join('\n') +
      '\n</Document></kml>\n';
  }
  function toCSV(list) {
    const q = (s) => `"${String(s ?? '').replace(/"/g, '""')}"`;
    return 'name,latitude,longitude,note\n' + list.map((p) => [q(p.name), p.lat.toFixed(6), p.lon.toFixed(6), q(p.note)].join(',')).join('\n') + '\n';
  }
  function parseImport(text, fileName) {
    const out = [];
    if (/<gpx|<kml/i.test(text)) {
      const doc = new DOMParser().parseFromString(text, 'application/xml');
      for (const w of doc.querySelectorAll('wpt, rtept')) {
        const lat = +w.getAttribute('lat'), lon = +w.getAttribute('lon');
        if (ok(lat, lon)) out.push({ name: (w.querySelector('name') || {}).textContent || 'Imported place', note: (w.querySelector('desc') || {}).textContent || '', lat, lon });
      }
      for (const pm of doc.querySelectorAll('Placemark')) {
        const c = (pm.querySelector('Point coordinates') || {}).textContent;
        if (!c) continue;
        const [lon, lat] = c.trim().split(',').map(Number);
        if (ok(lat, lon)) out.push({ name: (pm.querySelector('name') || {}).textContent || 'Imported place', note: (pm.querySelector('description') || {}).textContent || '', lat, lon });
      }
      return out;
    }
    // CSV, or one place per line: "name, lat, lon" / a Google link / "lat, lon"
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim() || /^name\s*,/i.test(line)) continue;
      const cells = line.match(/("([^"]|"")*"|[^,]*)(,|$)/g).map((c) => c.replace(/,$/, '').replace(/^"|"$/g, '').replace(/""/g, '"').trim());
      if (cells.length >= 3 && ok(+cells[1], +cells[2])) { out.push({ name: cells[0] || 'Imported place', lat: +cells[1], lon: +cells[2], note: cells[3] || '' }); continue; }
      const p = parseCoords(line);
      if (p) out.push({ name: p.name || line.replace(/https?:\S+/g, '').replace(/-?\d+\.\d+\s*,\s*-?\d+\.\d+/, '').trim() || 'Imported place', lat: p.lat, lon: p.lon, note: '' });
    }
    return out;
  }

  root.Geo = { distM, fmtDist, here, reverse, nearby, search, parseCoords, isShortLink, navLinks, toGPX, toKML, toCSV, parseImport, isIOS, isAndroid };
})(typeof self !== 'undefined' ? self : globalThis);
