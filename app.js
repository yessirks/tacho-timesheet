/* Tacho Timesheet: UI glue. Data flow: .ddd → Tacho.parse → Week.computeWeek → (auto values + your edits) → TimesheetPDF.build */
(function () {
  'use strict';
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const uid = () => Math.random().toString(36).slice(2, 10);
  const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const TYPES = { parking: 'Parking', tolls: 'Bridge / toll', food: 'Food', market: 'Other' };
  const DAY_KEYS = ['startTime', 'finishTime', 'startPlace', 'finishPlace', 'drops', 'nightOut', 'driving', 'stayed'];
  const PROFILE_KEYS = ['name', 'nameLine', 'addr1', 'addr2', 'ni', 'declaration', 'page2'];

  // ---- storage --------------------------------------------------------------
  const LS = {
    get(k, d) { try { const v = localStorage.getItem('tt.' + k); return v ? JSON.parse(v) : d; } catch { return d; } },
    set(k, v) { try { localStorage.setItem('tt.' + k, JSON.stringify(v)); } catch (e) { console.warn('save failed', e); } },
  };
  const memKV = new Map();
  const idb = (() => {
    let p;
    const open = () => p || (p = new Promise((res, rej) => {
      const r = indexedDB.open('tacho-timesheet', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('kv');
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    }));
    // Storage can hang (private mode, a blocked upgrade…); give up after 3s and keep going in memory.
    const timeout = (ms) => new Promise((_, rej) => setTimeout(() => rej(new Error('storage timeout')), ms));
    const tx = async (mode, fn) => {
      const db = await Promise.race([open(), timeout(3000)]);
      return Promise.race([timeout(3000), new Promise((res, rej) => {
        const t = db.transaction('kv', mode), req = fn(t.objectStore('kv'));
        t.oncomplete = () => res(req && req.result); t.onerror = () => rej(t.error);
      })]);
    };
    return {
      get: (k) => tx('readonly', (s) => s.get(k)).catch(() => memKV.get(k)),
      set: (k, v) => { memKV.set(k, v); return tx('readwrite', (s) => s.put(v, k)).catch((e) => console.warn('not saved', k, e)); },
      entries: async () => {
        try {
          const ks = await tx('readonly', (s) => s.getAllKeys()), vs = await tx('readonly', (s) => s.getAll());
          return ks.map((k, i) => [k, vs[i]]);
        } catch { return [...memKV.entries()]; }
      },
    };
  })();

  let profile = LS.get('profile', {});
  let places = LS.get('places', []);
  let stars = LS.get('stars', []);   // starred exact spots (gate entrances): { id, name, lat, lon, note }
  const geo = LS.get('geo', {});
  const diary = LS.get('diary', {});   // "YYYY-MM-DD" -> { start, finish, drops }; shared by the Diary tab and the timesheet
  for (const [d, v] of Object.entries(diary)) diary[d] = normalizeEntry(v);   // older versions kept drops as text
  // Sites that OpenStreetMap doesn't name well. Your own saved places win over these.
  const KNOWN_PLACES = [
    { name: 'Trewithen Dairy', lat: 50.4434, lon: -4.6394, radius: 700 },
    { name: 'Dunbia Treburley', lat: 50.5753, lon: -4.3330, radius: 900 },
    { name: 'Ornua Foods Leek', lat: 53.0961, lon: -2.0348, radius: 600 },
    { name: 'Gordano Services', lat: 51.4762, lon: -2.7080, radius: 600 },
  ];
  let card = null, prep = null, week = null, weekKey = null, ws = null;

  // Older versions stored drops as one line of text; turn it into the typed list.
  function parseStops(text) {
    return String(text || '').split(/[,\n]+/).map((t) => t.trim()).filter(Boolean).map((t) => {
      let m;
      if ((m = t.match(/^(?:load(?:ed)?(?: from)?|pick ?up|collect(?:ion)?)[:\s]+(.+)/i))) return { type: 'pickup', name: m[1] };
      if ((m = t.match(/^uncoupl\w*[:\s]+(.+)/i))) return { type: 'uncouple', name: m[1] };
      if ((m = t.match(/^coupl\w*[:\s]+(.+)/i))) return { type: 'couple', name: m[1] };
      if ((m = t.match(/^drop(?:ped)?[:\s]+(.+)/i))) return { type: 'drop', name: m[1] };
      return { type: 'drop', name: t };
    });
  }
  function normalizeEntry(e) {
    if (typeof e === 'string') e = { drops: e };
    e = { ...e };
    if (typeof e.drops === 'string') { if (!e.stops) e.stops = parseStops(e.drops); delete e.drops; }
    return e;
  }

  // ---- dates ----------------------------------------------------------------
  const ord = (n) => n + (n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th');
  const parts = (key) => { const [y, m, d] = key.split('-').map(Number); return { y, m, d }; };
  const fmtLong = (key) => { const { y, m, d } = parts(key); return `${ord(d)} ${MONTHS[m - 1]} ${y}`; };
  const fmtShort = (key) => { const { y, m, d } = parts(key); return `${String(d).padStart(2, '0')}/${String(m).padStart(2, '0')}/${y}`; };
  const fmtDay = (key) => { const { m, d } = parts(key); return `${d} ${MONTHS[m - 1].slice(0, 3)}`; };
  const todayKey = () => Week.localKey(Date.now());

  // ---- places / geocoding ---------------------------------------------------
  const geoKey = (p) => p.lat.toFixed(3) + ',' + p.lon.toFixed(3);
  const basePlace = () => places.find((p) => p.base) || null;
  function savedAt(pos, mineOnly) {
    const pick = (list) => {
      let best = null, bd = Infinity;
      for (const p of list) { const d = Week.distKm(p, pos) * 1000; if (d <= (p.radius || 500) && d < bd) { best = p; bd = d; } }
      return best;
    };
    const mine = pick(places);
    if (mine && mine.name) return mine;
    if (mineOnly) return mine;
    return pick(stars.map((x) => ({ ...x, radius: x.radius || 200 }))) || pick(KNOWN_PLACES) || mine;
  }
  const geoQueue = [], geoFailed = new Set();
  let geoBusy = false;
  function label(pos) {
    if (!pos) return '';
    const sp = savedAt(pos);
    if (sp && sp.name) return sp.name;
    const g = geo[geoKey(pos)];
    if (g) return g.label;
    if (profile.geocode !== 'no' && !geoFailed.has(geoKey(pos)) && !geoQueue.some((q) => geoKey(q) === geoKey(pos))) { geoQueue.push(pos); pumpGeo(); }
    return '';
  }
  function parseGeo(j) {
    const a = j.address || {};
    const town = a.village || a.town || a.city || a.hamlet || a.suburb || a.municipality || a.county || '';
    const c = j.category, t = j.type;
    // Only trust the exact feature name for things a lorry actually stops at.
    const poi = (c === 'highway' && (t === 'services' || t === 'rest_area')) || (c === 'amenity' && (t === 'fuel' || t === 'truck_stop'))
      || ['industrial', 'man_made', 'office', 'craft'].includes(c) || (c === 'landuse' && t === 'industrial')
      || (c === 'shop' && ['supermarket', 'wholesale', 'doityourself', 'department_store'].includes(t))
      || (c === 'building' && ['warehouse', 'industrial', 'commercial', 'retail'].includes(t));
    return { label: (poi && j.name) || town, town, postcode: a.postcode || '', cc: (a.country_code || '').toUpperCase(), display: j.display_name || '' };
  }
  async function pumpGeo() {
    if (geoBusy) return;
    geoBusy = true;
    while (geoQueue.length) {
      const pos = geoQueue[0], k = geoKey(pos);
      setStatus(`Looking up ${geoQueue.length} place name${geoQueue.length > 1 ? 's' : ''}…`);
      if (!geo[k]) {
        try {
          const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${pos.lat.toFixed(5)}&lon=${pos.lon.toFixed(5)}&zoom=18&addressdetails=1&accept-language=en`);
          if (!r.ok) throw new Error('HTTP ' + r.status);
          geo[k] = parseGeo(await r.json());
          LS.set('geo', geo);
        } catch (e) { console.warn('geocode failed', e); geoFailed.add(k); }
        await new Promise((r) => setTimeout(r, 1100));   // Nominatim allows 1 request/second
      }
      geoQueue.shift();
      refreshAuto();
      if (calMonth && $('#tab-diary').classList.contains('on')) { renderCalGrid(); fillCalEditor(); }
    }
    geoBusy = false;
    setStatus('');
  }
  function learnPlace(pos, name) {
    const sp = savedAt(pos, true);
    if (sp) sp.name = name; else places.push({ id: uid(), name, lat: pos.lat, lon: pos.lon, radius: 500, base: false });
    LS.set('places', places);
    renderPlaces();
  }
  const mapLink = (pos) => pos ? `https://www.openstreetmap.org/?mlat=${pos.lat.toFixed(5)}&mlon=${pos.lon.toFixed(5)}#map=16/${pos.lat.toFixed(5)}/${pos.lon.toFixed(5)}` : '';
  const coordText = (pos) => pos ? `${pos.lat.toFixed(4)}, ${pos.lon.toFixed(4)}` : '';

  // ---- values: tacho (auto) + your edits ---------------------------------------
  // Which tacho values get filled in automatically (anything can still be typed by hand).
  const FILL_OPTS = { times: 'Start/finish times', places: 'Places', drops: 'Drops (Load/Unload GPS)', nightOut: 'Nights out',
    driving: 'Driving hours', stayed: 'Page 2 "Place"', vehicle: 'Vehicle reg', totals: 'Totals & 24hr away' };
  const on = (k) => !profile.fill || profile.fill[k] !== false;
  function setupFill() {
    const box = $('#fillOpts');
    box.innerHTML = Object.entries(FILL_OPTS).map(([k, v]) =>
      `<label class="check"><input type="checkbox" data-fill="${k}" ${on(k) ? 'checked' : ''}> ${v}</label>`).join('');
    $$('[data-fill]', box).forEach((cb) => cb.onchange = () => {
      profile.fill = { ...(profile.fill || {}), [cb.dataset.fill]: cb.checked };
      LS.set('profile', profile);
      if (ws) { refreshAuto(true); refreshFoot(true); }
    });
  }
  function autoDay(i) {
    const r = week && week.rows[i], n = dget(Week.addDays(weekKey, i));
    if (!r || !r.startTime) return { startTime: '', finishTime: '', startPlace: n.start || '', finishPlace: n.finish || '', drops: fmtStops(n.stops), nightOut: '', driving: '', stayed: '' };
    // Only exact positions are filled in; rough ones are shown as a hint in the empty field.
    const at = (fix) => (on('places') && fix && fix.exact ? label(fix.pos) : '');
    return {
      startTime: on('times') ? r.startTime : '', finishTime: on('times') ? r.finishTime : '',
      // What you wrote in the diary wins; otherwise the tacho's GPS places and Load/Unload drops.
      startPlace: n.start || at(r.startFix), finishPlace: n.finish || at(r.endFix),
      drops: fmtStops(n.stops) || (on('drops') ? fmtStops(gpsStops(r)) : ''),
      nightOut: on('nightOut') ? r.nightOut : '', driving: on('driving') ? r.driving : '', stayed: '',
    };
  }
  function dayVal(i, k) {
    const o = ws.days[i] || {};
    if (k in o) return o[k];
    if (k === 'stayed') return on('stayed') && dayVal(i, 'nightOut') ? dayVal(i, 'finishPlace') : '';
    return autoDay(i)[k];
  }
  function autoFoot() {
    if (!on('totals')) return { ...autoFootAll(), totalWeekdays: '', totalWeekendDays: '', away24: '' };
    return autoFootAll();
  }
  function autoFootAll() {
    const worked = [0, 1, 2, 3, 4, 5, 6].map((i) => !!(dayVal(i, 'startTime') || dayVal(i, 'finishTime')));
    const id = card && card.identification;
    return {
      totalWeekdays: String(worked.slice(1, 6).filter(Boolean).length),
      totalWeekendDays: String((worked[0] ? 1 : 0) + (worked[6] ? 1 : 0)),
      away24: [0, 1, 2, 3, 4, 5, 6].some((i) => dayVal(i, 'nightOut')) ? 'YES' : 'NO',
      declaration: '',
      name: id ? `${id.surname} ${id.firstNames}` : '',
      weekCommencing: fmtLong(weekKey),
      nameLine: id ? `${id.firstNames} ${id.surname}`.toUpperCase() : '',
      addr1: '', addr2: '', ni: '',
      vehicle: on('vehicle') ? (week && week.vehicle) || '' : '',
      signedDate: fmtShort(todayKey()),
      weDate: fmtShort(Week.addDays(weekKey, 6)),
      page2: 'yes',
    };
  }
  function footVal(k) {
    if (PROFILE_KEYS.includes(k) && profile[k] !== undefined) return profile[k];
    if (k in ws.foot) return ws.foot[k];
    return autoFoot()[k];
  }

  // ---- loading ----------------------------------------------------------------
  async function loadCard(bytes, name, save) {
    try {
      card = Tacho.parse(new Uint8Array(bytes));
    } catch (e) { alert('Could not read this file: ' + e.message); return; }
    prep = Week.prepare(card);
    if (!basePlace()) {
      const b = Week.guessBase(prep);
      if (b) { places.push({ id: uid(), name: '', lat: b.lat, lon: b.lon, radius: 1500, base: true }); LS.set('places', places); }
    }
    if (save) idb.set('card', { name, bytes });
    const id = card.identification, days = card.days;
    const span = days.length ? `${fmtShort(Week.localKey(+days[0].date))} – ${fmtShort(Week.localKey(+days[days.length - 1].date))}` : 'no activity';
    $('#cardInfo').innerHTML = `<b>${esc(id.firstNames)} ${esc(id.surname)}</b> · card ${esc(id.cardNumber)} · activity ${span}` +
      (card.lastDownload ? ` · downloaded ${fmtShort(Week.localKey(+card.lastDownload))}` : '') + ` · <span class="muted">${esc(name || '')}</span>`;
    $('#dropZone').classList.add('hidden');
    renderPlaces();
    buildWeekList();
  }

  function buildWeekList(keep) {
    let weeks = prep ? Week.listWeeks(prep) : [];
    if (!weeks.length) {   // no card: offer recent weeks for a manual timesheet
      const s = Week.sundayOf(Date.now());
      weeks = Array.from({ length: 12 }, (_, i) => Week.addDays(s, -7 * i));
    }
    const sel = $('#weekSel');
    sel.innerHTML = weeks.map((k) => {
      const n = prep ? prep.shifts.filter((s) => Week.sundayOf(s.cardIn || s.start) === k).length : 0;
      return `<option value="${k}">w/c Sunday ${fmtLong(k)}${n ? ` · ${n} shift${n > 1 ? 's' : ''}` : ''}</option>`;
    }).join('');
    const want = keep && weeks.includes(keep) ? keep : weeks[0];
    sel.value = want;
    selectWeek(want);
    annotateWeeks();
  }

  async function selectWeek(key) {
    weekKey = key;
    week = card ? Week.computeWeek(card, prep, key, { base: basePlace(), awayKm: +profile.awayKm || 25 }) : null;
    ws = weekStates.get(key) || (await idb.get('week:' + key)) || blankWeek();
    weekStates.set(key, ws);
    weekCache.clear();
    ws.days.forEach((o, i) => {   // places and drops used to be saved per week; they live in the diary now
      for (const [k, f] of Object.entries({ ...DIARY_FIELD, drops: 'drops' })) {
        if (!(k in o)) continue;
        const d = Week.addDays(key, i);
        if (k !== 'drops' && o[k].trim() && !dget(d)[f]) setDiary(d, f, o[k]);
        if (k === 'drops' && o[k].trim() && !dget(d).stops) setDiary(d, 'stops', parseStops(o[k]));
        delete o[k]; saveWeek();
      }
    });
    const n = week ? week.rows.filter((r) => r.startTime).length : 0;
    $('#weekInfo').textContent = `${fmtShort(key)} – ${fmtShort(Week.addDays(key, 6))}` + (card ? ` · ${n} day${n === 1 ? '' : 's'} on the tacho` : ' · no card loaded: fill in by hand');
    renderDays(); renderFoot(); renderExpenses(); renderOther(); showDone();
    if (!calSel || !inWeek(calSel)) { calSel = inWeek(todayKey()) ? todayKey() : key; calMonth = calSel.slice(0, 7); }
    if ($('#tab-diary').classList.contains('on')) renderCal();
    schedulePdf();
  }

  let saveT;
  function saveWeek() {
    ws.editedAt = Date.now(); showDone();
    clearTimeout(saveT); const k = weekKey, v = ws; saveT = setTimeout(() => idb.set('week:' + k, v), 300);
  }

  // ---- rendering: days ------------------------------------------------------------
  function renderDays() {
    const box = $('#days');
    box.innerHTML = '';
    for (let i = 0; i < 7; i++) {
      const r = week && week.rows[i], date = Week.addDays(weekKey, i);
      const el = document.createElement('div');
      const has = !!(r && r.startTime), edited = Object.keys(ws.days[i] || {}).length > 0 || !!diary[date];
      el.className = 'day' + (has ? '' : ' off') + (has || edited ? '' : ' collapsed');
      const tags = [];
      if (r && r.shifts.length > 1) tags.push(`<span class="tag warn">${r.shifts.length} shifts merged</span>`);
      if (r && r.finishNote) tags.push(`<span class="tag warn">finishes ${r.finishNote}</span>`);
      if (r && r.startTime) tags.push(`<span class="tag">other work ${Week.hm(r.workMin)} · driving ${r.driving}</span>`);
      if (!r || !r.startTime) tags.push('<span class="tag">no tacho activity</span>');
      el.innerHTML = `
        <div class="day-head"><b>${DAYS[i]} ${fmtDay(date)}</b>${tags.join('')}
          <button class="btn small link expand" style="margin-left:auto">Fill in by hand</button>
          <button class="btn small link reset" title="Put the tacho values back" style="margin-left:auto">↺ reset</button></div>
        <div class="day-grid">
          <label class="f">Start time<input data-d="${i}" data-k="startTime" placeholder="hh:mm"></label>
          <label class="f">Finish time<input data-d="${i}" data-k="finishTime" placeholder="hh:mm"></label>
          <label class="f"><span>Start place <a class="pin" data-pin="start" target="_blank" rel="noopener"></a></span><input data-d="${i}" data-k="startPlace"></label>
          <label class="f"><span>Finish place <a class="pin" data-pin="end" target="_blank" rel="noopener"></a></span><input data-d="${i}" data-k="finishPlace"></label>
        </div>
        <div style="margin-top:10px"><span class="lbl">Drops, pickups, coupling</span><div class="stops-ed"></div></div>
        <div class="day-grid2">
          <label class="f">Night out<select data-d="${i}" data-k="nightOut"><option value="">No</option><option>UK</option><option>EU</option></select></label>
          <label class="f">Driving hrs<input data-d="${i}" data-k="driving"></label>
          <label class="f">Stayed at (page 2 "Place")<input data-d="${i}" data-k="stayed"></label>
        </div>
        <div class="chips"></div>`;
      const chips = $('.chips', el);
      if (r && r.drops.length) r.drops.forEach((d) => {
        const c = document.createElement('button');
        c.className = 'chip gps'; c.type = 'button';
        c.title = 'Recorded on the tacho with GPS. Click to add to drops.';
        c.dataset.time = d.time; c.dataset.day = i;
        chips.appendChild(c);
      });
      if (r && r.stops.length) {
        const s = document.createElement('span');
        s.className = 'small muted';
        s.textContent = 'Stops with work: ' + r.stops.map((x) => `${x.label} (${x.work}m)`).join(', ');
        s.title = 'Periods of other work between drives. Likely drops or collections; the card has no GPS for these.';
        chips.appendChild(s);
      }
      $('.expand', el).onclick = () => el.classList.remove('collapsed');
      $('.reset', el).onclick = () => { ws.days[i] = {}; saveWeek(); refreshAuto(true); schedulePdf(); };
      box.appendChild(el);
      el.stopsEd = stopsEditor($('.stops-ed', el), date);
    }
    $$('[data-d]', box).forEach((inp) => {
      const i = +inp.dataset.d, k = inp.dataset.k;
      inp.addEventListener('input', () => {
        if (DIARY_FIELD[k]) setDiary(Week.addDays(weekKey, i), DIARY_FIELD[k], inp.value); else ws.days[i][k] = inp.value;
        inp.classList.add('edited'); inp.classList.remove('auto');
        saveWeek(); refreshFoot(); schedulePdf();
      });
      if (k === 'startPlace' || k === 'finishPlace') inp.addEventListener('change', () => {
        const r = week && week.rows[i], fix = r && (k === 'startPlace' ? r.startFix : r.endFix);
        if (profile.learn !== 'no' && fix && fix.exact && inp.value.trim()) {
          learnPlace(fix.pos, inp.value.trim());
          weekCache.clear(); refreshAuto(true); schedulePdf();
        }
      });
    });
    $$('.chip.gps', box).forEach((c) => c.onclick = () => {
      const day = c.closest('.day'), r = week.rows[+c.dataset.day], d = r.drops.find((x) => String(x.time) === c.dataset.time);
      day.stopsEd.add({ type: d.op === 1 ? 'pickup' : 'drop', name: label(d.pos) || coordText(d.pos) });
    });
    refreshAuto(true);
  }

  // Write auto values into every field you haven't edited (skips the one you're typing in).
  function refreshAuto(force) {
    if (!ws) return;
    $$('[data-d]').forEach((inp) => {
      const i = +inp.dataset.d, k = inp.dataset.k;
      const edited = DIARY_FIELD[k] ? !!dget(Week.addDays(weekKey, i))[DIARY_FIELD[k]] : k in (ws.days[i] || {});
      if (!force && document.activeElement === inp) return;
      const v = dayVal(i, k);
      if (inp.value !== v) inp.value = v;
      inp.classList.toggle('edited', edited); inp.classList.toggle('auto', !edited && !!v);
      if (k === 'startPlace' || k === 'finishPlace') {
        const r = week && week.rows[i], fix = r && (k === 'startPlace' ? r.startFix : r.endFix);
        const g = fix && fix.pos && geo[geoKey(fix.pos)];
        inp.placeholder = !fix ? '' : fix.exact ? coordText(fix.pos) : 'roughly near ' + (label(fix.pos) || coordText(fix.pos));
        inp.title = g ? g.display : '';
        const pin = $(`a[data-pin="${k === 'startPlace' ? 'start' : 'end'}"]`, inp.closest('.day'));
        if (pin) { pin.textContent = fix && fix.pos ? 'map' + (fix.exact ? '' : ' (rough)') : ''; pin.href = mapLink(fix && fix.pos); }
      }
    });
    $$('.chip.gps').forEach((c) => {
      const r = week.rows[+c.dataset.day], d = r.drops.find((x) => String(x.time) === c.dataset.time);
      const l = label(d.pos) || coordText(d.pos);
      c.dataset.label = (d.op === 1 ? 'Load ' : '') + l;
      c.textContent = `${Week.local(d.time).time} ${d.opName} · ${l}`;
    });
    refreshFoot();
    schedulePdf();
  }

  // ---- rendering: footer / profile --------------------------------------------------
  function renderFoot() {
    $$('[data-k]:not([data-d])').forEach((inp) => {
      const k = inp.dataset.k;
      inp.oninput = inp.onchange = () => {
        if (PROFILE_KEYS.includes(k)) { profile[k] = inp.value; LS.set('profile', profile); }
        else { ws.foot[k] = inp.value; saveWeek(); }
        inp.classList.add('edited');
        schedulePdf();
      };
    });
    refreshFoot(true);
  }
  function refreshFoot(force) {
    if (!ws) return;
    $$('[data-k]:not([data-d])').forEach((inp) => {
      if (!force && document.activeElement === inp) return;
      const k = inp.dataset.k, v = footVal(k) ?? '';
      if (inp.value !== v) inp.value = v;
      const edited = PROFILE_KEYS.includes(k) ? false : k in ws.foot;
      inp.classList.toggle('edited', edited);
    });
  }

  // ---- expenses & attachments ---------------------------------------------------------
  async function readAttachment(file) {
    const mime = file.type || (/\.pdf$/i.test(file.name) ? 'application/pdf' : '');
    if (mime === 'application/pdf') return { id: uid(), name: file.name, mime, kind: 'pdf', data: await file.arrayBuffer(), thumb: null };
    let bmp;
    try { bmp = await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch (e) {
      throw new Error(`Could not open ${file.name}.` + (/hei[cf]/i.test(file.name + mime) ? ' iPhone HEIC photos need to be shared as JPG (Settings › Camera › Formats › Most Compatible).' : ''));
    }
    const k = Math.min(1, 1800 / Math.max(bmp.width, bmp.height));
    const cv = document.createElement('canvas');
    cv.width = Math.round(bmp.width * k); cv.height = Math.round(bmp.height * k);
    const cx = cv.getContext('2d'); cx.fillStyle = '#fff'; cx.fillRect(0, 0, cv.width, cv.height); cx.drawImage(bmp, 0, 0, cv.width, cv.height);
    const blob = await new Promise((r) => cv.toBlob(r, 'image/jpeg', 0.85));
    const t = document.createElement('canvas'), tk = 96 / Math.max(cv.width, cv.height);
    t.width = Math.round(cv.width * tk); t.height = Math.round(cv.height * tk); t.getContext('2d').drawImage(cv, 0, 0, t.width, t.height);
    return { id: uid(), name: file.name, mime: 'image/jpeg', kind: 'image', data: await blob.arrayBuffer(), thumb: t.toDataURL('image/jpeg', 0.7) };
  }
  const attThumb = (a) => a.kind === 'pdf' ? '<span class="tag">PDF</span>' : `<img class="thumb" src="${a.thumb}" alt="">`;

  function renderExpenses() {
    refreshDayExpenses();
    const tb = $('#expBody');
    tb.innerHTML = ws.expenses.map((e, n) => `<tr data-n="${n}">
      <td><select data-e="day">${DAYS.map((d, i) => `<option value="${i}" ${+e.day === i ? 'selected' : ''}>${d.slice(0, 3)} ${fmtDay(Week.addDays(weekKey, i))}</option>`).join('')}</select></td>
      <td><select data-e="type">${Object.entries(TYPES).map(([k, v]) => `<option value="${k}" ${e.type === k ? 'selected' : ''}>${v}</option>`).join('')}</select></td>
      <td><input data-e="note" value="${esc(e.note)}" placeholder="e.g. M6 toll"></td>
      <td class="num"><input data-e="amount" type="number" step="0.01" min="0" value="${esc(e.amount)}"></td>
      <td class="num"><input data-e="vat" type="number" step="0.01" min="0" value="${esc(e.vat)}"></td>
      <td>${e.att ? `${attThumb(e.att)} <button class="btn small link" data-act="unatt" title="Remove receipt">×</button>`
        : '<label class="btn small">📷 Scan<input type="file" data-act="scan" accept="image/*" capture="environment" hidden></label> <label class="btn small">📎 File<input type="file" data-act="att" accept="image/*,application/pdf" hidden></label>'}</td>
      <td><button class="btn small link" data-act="del" title="Delete row">✕</button></td></tr>`).join('')
      || '<tr><td colspan="7" class="muted small">No expenses this week.</td></tr>';
    $$('tr[data-n]', tb).forEach((tr) => {
      const e = ws.expenses[+tr.dataset.n];
      $$('[data-e]', tr).forEach((inp) => inp.oninput = inp.onchange = () => { e[inp.dataset.e] = inp.value; saveWeek(); schedulePdf(); refreshDayExpenses(); });
      const del = $('[data-act="del"]', tr); del.onclick = () => { ws.expenses.splice(+tr.dataset.n, 1); saveWeek(); renderExpenses(); schedulePdf(); };
      const un = $('[data-act="unatt"]', tr); if (un) un.onclick = () => { delete e.att; saveWeek(); renderExpenses(); schedulePdf(); };
      const at = $('[data-act="att"]', tr);
      if (at) at.onchange = async () => {
        try { e.att = await readAttachment(at.files[0]); } catch (err) { alert(err.message); return; }
        saveWeek(); renderExpenses(); schedulePdf();
      };
      const sc = $('[data-act="scan"]', tr);
      if (sc) sc.onchange = async () => {
        const f = sc.files[0]; sc.value = '';
        if (!f) return;
        const scanned = await Scanner.open(f);
        if (!scanned) return;
        try { e.att = await readAttachment(scanned); e.att.scanned = true; } catch (err) { alert(err.message); return; }
        saveWeek(); renderExpenses(); schedulePdf(); toast('Receipt scanned');
      };
      const tv = $('.thumb, td .tag', tr);
      if (tv && e.att) tv.onclick = () => viewAttachment(e.att);
    });
  }
  function renderOther() {
    const box = $('#otherAtt');
    box.innerHTML = ws.other.map((a, n) => `<span class="chip" style="display:flex;gap:6px;align-items:center;cursor:default" data-n="${n}">${attThumb(a)}
      <input data-o="caption" value="${esc(a.caption || '')}" placeholder="Caption (optional)" style="width:170px">
      <button class="btn small link" data-act="del" title="Remove">✕</button></span>`).join('');
    $$('[data-n]', box).forEach((el) => {
      const a = ws.other[+el.dataset.n];
      $('[data-o]', el).oninput = (ev) => { a.caption = ev.target.value; saveWeek(); schedulePdf(); };
      $('[data-act="del"]', el).onclick = () => { ws.other.splice(+el.dataset.n, 1); saveWeek(); renderOther(); schedulePdf(); };
    });
  }

  // ---- signature ---------------------------------------------------------------------
  function trimCanvas(cv) {   // crop to the ink, keep transparency
    const cx = cv.getContext('2d'), { width: w, height: h } = cv, d = cx.getImageData(0, 0, w, h).data;
    let x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (d[(y * w + x) * 4 + 3] > 20) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    if (x1 < 0) return null;
    const pad = 6, o = document.createElement('canvas');
    o.width = x1 - x0 + 1 + pad * 2; o.height = y1 - y0 + 1 + pad * 2;
    o.getContext('2d').drawImage(cv, x0 - pad, y0 - pad, o.width, o.height, 0, 0, o.width, o.height);
    return o.toDataURL('image/png');
  }
  function setupSignature() {
    const cv = $('#sig'), cx = cv.getContext('2d');
    let drawing = false, last = null;
    cx.lineCap = 'round'; cx.lineJoin = 'round'; cx.strokeStyle = '#0f2a80'; cx.lineWidth = 5;
    const pt = (e) => { const r = cv.getBoundingClientRect(); return { x: (e.clientX - r.left) * cv.width / r.width, y: (e.clientY - r.top) * cv.height / r.height }; };
    cv.onpointerdown = (e) => { drawing = true; last = pt(e); cv.setPointerCapture(e.pointerId); };
    cv.onpointermove = (e) => { if (!drawing) return; const p = pt(e); cx.beginPath(); cx.moveTo(last.x, last.y); cx.lineTo(p.x, p.y); cx.stroke(); last = p; };
    cv.onpointerup = cv.onpointercancel = () => { drawing = false; };
    $('#sigClear').onclick = () => cx.clearRect(0, 0, cv.width, cv.height);
    $('#sigSave').onclick = () => { const u = trimCanvas(cv); if (!u) return alert('Sign in the box first.'); profile.signature = u; LS.set('profile', profile); showSig(); schedulePdf(); };
    $('#sigRemove').onclick = () => { delete profile.signature; LS.set('profile', profile); showSig(); schedulePdf(); };
    $('#sigUpload').onchange = async (ev) => {
      const f = ev.target.files[0]; if (!f) return;
      const bmp = await createImageBitmap(f, { imageOrientation: 'from-image' });
      const k = Math.min(1, 900 / bmp.width), t = document.createElement('canvas');
      t.width = Math.round(bmp.width * k); t.height = Math.round(bmp.height * k);
      const tc = t.getContext('2d'); tc.drawImage(bmp, 0, 0, t.width, t.height);
      const img = tc.getImageData(0, 0, t.width, t.height), d = img.data;
      for (let i = 0; i < d.length; i += 4) {   // paper → transparent, ink → blue-black
        const l = (d[i] + d[i + 1] + d[i + 2]) / 3, a = Math.max(0, Math.min(255, (200 - l) * 2.2));
        d[i] = 15; d[i + 1] = 30; d[i + 2] = 110; d[i + 3] = a;
      }
      tc.putImageData(img, 0, 0);
      profile.signature = trimCanvas(t); LS.set('profile', profile); showSig(); schedulePdf();
    };
    showSig();
  }
  function showSig() {
    const has = !!profile.signature;
    $('#sigImg').classList.toggle('hidden', !has); $('#sigRemove').classList.toggle('hidden', !has);
    if (has) $('#sigImg').src = profile.signature;
    $('#sigState').textContent = has ? '· saved' : '· not set yet';
  }

  // ---- saved places & settings --------------------------------------------------------------
  function renderPlaces() {
    const tb = $('#placesBody');
    tb.innerHTML = places.map((p, n) => {
      const g = geo[geoKey(p)];
      return `<tr data-n="${n}"><td><input type="radio" name="base" ${p.base ? 'checked' : ''} style="width:auto"></td>
        <td><input data-p="name" value="${esc(p.name)}" placeholder="${esc(g ? g.label : coordText(p))}"></td>
        <td style="width:90px"><input data-p="radius" type="number" min="50" step="50" value="${p.radius || 500}"></td>
        <td><a class="pin" href="${mapLink(p)}" target="_blank" rel="noopener">map</a></td>
        <td><button class="btn small link" data-act="del">✕</button></td></tr>`;
    }).join('') || '<tr><td colspan="5" class="muted">None yet. Load a card file, then type a name into a start/finish place.</td></tr>';
    $$('tr[data-n]', tb).forEach((tr) => {
      const p = places[+tr.dataset.n];
      const changed = (recompute) => { LS.set('places', places); if (recompute && weekKey) selectWeek(weekKey); else refreshAuto(); };
      $('[type=radio]', tr).onchange = () => { places.forEach((q) => q.base = q === p); changed(true); };
      $('[data-p=name]', tr).onchange = (e) => { p.name = e.target.value.trim(); changed(false); };
      $('[data-p=radius]', tr).onchange = (e) => { p.radius = +e.target.value || 500; changed(true); };
      $('[data-act=del]', tr).onclick = () => { places.splice(+tr.dataset.n, 1); renderPlaces(); changed(true); };
    });
  }
  function setupSettings() {
    $('#setGeo').value = profile.geocode || 'yes';
    $('#setLearn').value = profile.learn || 'yes';
    $('#setAway').value = profile.awayKm || 25;
    $('#setDropWord').value = profile.dropWord || 'no';
    $('#setDropWord').onchange = (e) => { profile.dropWord = e.target.value; LS.set('profile', profile); refreshAuto(); if (calMonth) renderCalGrid(); };
    $('#setGeo').onchange = (e) => { profile.geocode = e.target.value; LS.set('profile', profile); refreshAuto(); };
    $('#setLearn').onchange = (e) => { profile.learn = e.target.value; LS.set('profile', profile); };
    $('#setAway').onchange = (e) => { profile.awayKm = +e.target.value || 25; LS.set('profile', profile); if (weekKey) selectWeek(weekKey); };
    $('#exportSettings').onclick = exportAll;
    $('#importSettings').onchange = async (e) => {
      try {
        await importAll(e.target.files[0]);
        location.reload();
      } catch (err) { alert('That file could not be read: ' + err.message); }
    };
    $('#resetWeek').onclick = () => {
      if (!confirm('Clear your edits to the days and totals for this week? Expenses and photos are kept.')) return;
      ws.days = [{}, {}, {}, {}, {}, {}, {}]; ws.foot = {}; saveWeek(); refreshAuto(true); refreshFoot(true);
    };
  }

  // ---- diary (calendar) ----------------------------------------------------------------------
  // diary["YYYY-MM-DD"] = { start, finish, stops: [{ type, name }] }. What you write here always wins over the tacho.
  let calMonth = null, calSel = null;
  const weekCache = new Map();
  const DIARY_FIELD = { startPlace: 'start', finishPlace: 'finish' };
  const inWeek = (d) => weekKey && d >= weekKey && d <= Week.addDays(weekKey, 6);
  const dget = (date) => diary[date] || {};
  const sundayOfKey = (d) => Week.sundayOf(Date.parse(d + 'T12:00:00Z'));
  const dayIdx = (d) => new Date(Date.parse(d)).getUTCDay();
  function setDiary(date, field, v) {
    const e = { ...dget(date) };
    const empty = Array.isArray(v) ? !v.length : !(v && String(v).trim());
    if (empty) delete e[field]; else e[field] = v;
    if (Object.keys(e).length) diary[date] = e; else delete diary[date];
    LS.set('diary', diary);
    if (calMonth) renderCalGrid();
    if (date === calSel) fillCalEditor();
    updatePlaceList();
    if (ws && inWeek(date)) { saveWeek(); refreshAuto(); }
  }

  // ---- stops: drops, pickups, coupling ------------------------------------------------------------
  const STOP_TYPES = { drop: 'Drop', pickup: 'Pickup', couple: 'Couple', uncouple: 'Uncouple', other: 'Other' };
  // On the timesheet a drop is just its name, like you'd write it; the others say what happened.
  function fmtStop(s) {
    const name = (s.name || '').trim(), ref = (s.ref || '').trim();
    if (!name && !ref) return '';
    const what = name && ref ? `${name} (${ref})` : name || ref;
    return (s.type === 'drop' && profile.dropWord !== 'yes') || s.type === 'other' ? what : `${STOP_TYPES[s.type] || ''} ${what}`;
  }
  const fmtStops = (list) => (list || []).map(fmtStop).filter(Boolean).join(', ');
  const gpsStops = (r) => r.drops.map((d) => ({ type: d.op === 1 ? 'pickup' : 'drop', name: label(d.pos) || '…' }));
  const stopEditors = new Set();
  function stopsEditor(box, date) {
    const ed = { box, date };
    const list = () => (dget(date).stops || []).map((s) => ({ ...s }));
    const save = (l, redraw) => { setDiary(date, 'stops', l); if (redraw) draw(); syncStopEditors(ed); };
    function draw() {
      const l = list();
      box.innerHTML = `<div class="stops">${l.map((s, n) => `<div class="stop" data-n="${n}">
          <select data-s="type" aria-label="Type">${Object.entries(STOP_TYPES).map(([k, v]) => `<option value="${k}" ${s.type === k ? 'selected' : ''}>${v}</option>`).join('')}</select>
          <input data-s="name" list="placeNames" value="${esc(s.name)}" placeholder="Name, e.g. Sainsbury's Paignton" aria-label="Name">
          <input data-s="ref" value="${esc(s.ref || '')}" placeholder="Trailer / ref" aria-label="Trailer or reference">
          <button type="button" class="btn small loc${isFinite(s.lat) ? ' on' : ''}" data-s="loc" title="${isFinite(s.lat) ? 'Located. Tap to locate again' : 'Use my location'}">📍</button>
          <button type="button" class="btn small link" data-s="del" title="Remove">✕</button></div>`).join('')}</div>
        <div class="add-row">${['drop', 'pickup', 'couple', 'uncouple'].map((t) => `<button type="button" class="btn small" data-add="${t}">+ ${STOP_TYPES[t]}</button>`).join('')}</div>`;
      $$('.stop', box).forEach((row) => {
        const n = +row.dataset.n;
        $('[data-s=type]', row).onchange = (e) => { const l2 = list(); l2[n].type = e.target.value; save(l2); };
        $('[data-s=name]', row).oninput = (e) => { const l2 = list(); l2[n].name = e.target.value; save(l2); };
        $('[data-s=ref]', row).oninput = (e) => { const l2 = list(); l2[n].ref = e.target.value; save(l2); };
        $('[data-s=loc]', row).onclick = () => locatePicker(`📍 Where is this ${(STOP_TYPES[list()[n].type] || 'stop').toLowerCase()}?`, (name, pos) => {
          const l2 = list(); l2[n].name = name;
          if (pos) { l2[n].lat = pos.lat; l2[n].lon = pos.lon; }
          save(l2, true);
        });
        $('[data-s=del]', row).onclick = () => { const l2 = list(); l2.splice(n, 1); save(l2, true); };
      });
      $$('[data-add]', box).forEach((b) => b.onclick = () => {
        const l2 = list(); l2.push({ type: b.dataset.add, name: '' }); save(l2, true);
        const ins = $$('[data-s=name]', box); ins[ins.length - 1].focus();
      });
    }
    ed.draw = draw;
    ed.add = (s) => { const l2 = list().filter((x) => (x.name || '').trim()); l2.push(s); save(l2, true); };
    stopEditors.add(ed);
    draw();
    return ed;
  }
  function syncStopEditors(from) {
    for (const ed of [...stopEditors]) {
      if (!document.body.contains(ed.box)) { stopEditors.delete(ed); continue; }
      if (ed !== from && ed.date === from.date && !ed.box.contains(document.activeElement)) ed.draw();
    }
  }
  // Stops you've used before, most used first, for one-tap entry.
  function frequentStops() {
    const n = new Map(), hidden = new Set(profile.hiddenStops || []);
    for (const e of Object.values(diary)) for (const s of e.stops || []) {
      const name = (s.name || '').trim();
      if (name.length < 2) continue;
      const k = s.type + '|' + name.toLowerCase();
      if (hidden.has(k)) continue;
      const v = n.get(k) || { type: s.type, name, c: 0 };
      v.c++;
      if (isFinite(s.lat)) { v.lat = s.lat; v.lon = s.lon; }
      n.set(k, v);
    }
    return [...n.values()].sort((a, b) => b.c - a.c).slice(0, 18);
  }

  // ---- expenses for one day (lives in that week's saved state) ----------------------------------------
  const weekStates = new Map();
  const blankWeek = () => ({ days: [{}, {}, {}, {}, {}, {}, {}], foot: {}, expenses: [], other: [] });
  async function weekState(sun) {
    if (!weekStates.has(sun)) weekStates.set(sun, (await idb.get('week:' + sun)) || blankWeek());
    return weekStates.get(sun);
  }
  function saveWeekState(sun) {
    if (sun === weekKey) { saveWeek(); renderExpenses(); schedulePdf(); return; }
    const w = weekStates.get(sun);
    w.editedAt = Date.now();
    idb.set('week:' + sun, w);
  }
  function dayExpTotal(date) {
    const w = weekStates.get(sundayOfKey(date)), i = dayIdx(date);
    return w ? w.expenses.filter((e) => +e.day === i).reduce((a, e) => a + (parseFloat(e.amount) || 0), 0) : 0;
  }
  async function dayExpensesEditor(box, date) {
    const sun = sundayOfKey(date), i = dayIdx(date), w = await weekState(sun);
    if (calSel !== date) return;   // you've already moved to another day
    function draw() {
      const rows = w.expenses.map((e, n) => ({ e, n })).filter((x) => +x.e.day === i);
      const tot = rows.reduce((a, x) => a + (parseFloat(x.e.amount) || 0), 0);
      box.innerHTML = rows.map(({ e, n }) => `<div class="exp-row" data-n="${n}">
          <select data-e="type" aria-label="Type">${Object.entries(TYPES).map(([k, v]) => `<option value="${k}" ${e.type === k ? 'selected' : ''}>${v}</option>`).join('')}</select>
          <input data-e="note" value="${esc(e.note)}" placeholder="Note, e.g. Gordano" aria-label="Note">
          <input data-e="amount" type="number" step="0.01" min="0" inputmode="decimal" value="${esc(e.amount)}" placeholder="£" aria-label="Amount">
          <span class="exp-photo">${e.att ? `${attThumb(e.att)}<button type="button" class="btn small link" data-act="unatt" title="Remove photo">✕</button>`
            : '<label class="btn small">📷 Scan<input type="file" data-act="scan" accept="image/*" capture="environment" hidden></label><label class="btn small">📎 File<input type="file" data-act="att" accept="image/*,application/pdf" hidden></label>'}</span>
          <button type="button" class="btn small link" data-act="del" title="Delete">✕</button></div>`).join('') +
        `<div class="add-row">${Object.entries(TYPES).map(([k, v]) => `<button type="button" class="btn small" data-addexp="${k}">+ ${v}</button>`).join('')}</div>` +
        (tot ? `<div class="small" style="margin-top:6px">Total this day: <b>£${tot.toFixed(2)}</b></div>` : '');
      $$('.exp-row', box).forEach((row) => {
        const e = w.expenses[+row.dataset.n];
        $$('[data-e]', row).forEach((inp) => inp.oninput = inp.onchange = () => { e[inp.dataset.e] = inp.value; saveWeekState(sun); renderCalGrid(); });
        $('[data-act=del]', row).onclick = () => { w.expenses.splice(+row.dataset.n, 1); saveWeekState(sun); draw(); renderCalGrid(); };
        const un = $('[data-act=unatt]', row); if (un) un.onclick = () => { delete e.att; saveWeekState(sun); draw(); };
        const at = $('[data-act=att]', row);
        if (at) at.onchange = async () => {
          try { e.att = await readAttachment(at.files[0]); } catch (err) { alert(err.message); return; }
          saveWeekState(sun); draw(); toast('Receipt added to this day');
        };
        const sc = $('[data-act=scan]', row);
        if (sc) sc.onchange = async () => {
          const f = sc.files[0]; sc.value = '';
          if (!f) return;
          const scanned = await Scanner.open(f);
          if (!scanned) return;
          try { e.att = await readAttachment(scanned); e.att.scanned = true; } catch (err) { alert(err.message); return; }
          saveWeekState(sun); draw(); toast('Receipt scanned and saved to this day');
        };
        const tv = $('.exp-photo .thumb, .exp-photo .tag', row);
        if (tv && e.att) tv.onclick = () => viewAttachment(e.att);
      });
      $$('[data-addexp]', box).forEach((b) => b.onclick = () => {
        w.expenses.push({ id: uid(), day: i, type: b.dataset.addexp, note: '', amount: '', vat: '' });
        saveWeekState(sun); draw();
        const am = $$('[data-e=amount]', box); am[am.length - 1].focus();
      });
    }
    box.redraw = draw;
    draw();
  }
  // Keep the diary's expense list in step when the weekly table changes.
  function refreshDayExpenses() {
    const box = $('#calExp');
    if (box && box.redraw && inWeek(calSel) && !box.contains(document.activeElement)) box.redraw();
  }

  // ---- calendar ---------------------------------------------------------------------------------
  // The timesheet row the tacho gives for any date (computed per week, cached).
  function tachoDay(date) {
    if (!card) return null;
    const s = sundayOfKey(date);
    if (!weekCache.has(s)) weekCache.set(s, Week.computeWeek(card, prep, s, { base: basePlace(), awayKm: +profile.awayKm || 25 }));
    const r = weekCache.get(s).rows[dayIdx(date)];
    return r && r.startTime ? r : null;
  }
  const fixLabel = (fix) => (fix && fix.exact ? label(fix.pos) : '');
  // Suggestions for every place and stop box: saved places, built-in sites and everything in the diary.
  function updatePlaceList() {
    const names = new Set();
    for (const p of places) if (p.name) names.add(p.name);
    for (const p of KNOWN_PLACES) names.add(p.name);
    for (const p of stars) names.add(p.name);
    for (const e of Object.values(diary)) {
      if (e.start) names.add(e.start);
      if (e.finish) names.add(e.finish);
      for (const s of e.stops || []) if ((s.name || '').trim()) names.add(s.name.trim());
    }
    $('#placeNames').innerHTML = [...names].sort().map((n) => `<option value="${esc(n)}">`).join('');
  }
  let calLoading = false;
  function renderCalGrid() {
    const [y, m] = calMonth.split('-').map(Number);
    $('#calTitle').textContent = `${MONTHS[m - 1]} ${y}`;
    const start = Week.addDays(`${calMonth}-01`, -new Date(Date.UTC(y, m - 1, 1)).getUTCDay()), today = todayKey();
    const missing = [];
    let html = ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d) => `<div class="cal-h">${d}</div>`).join('');
    for (let i = 0; i < 42; i++) {
      const d = Week.addDays(start, i);
      if (i === 35 && d.slice(0, 7) !== calMonth) break;
      if (i % 7 === 0 && !weekStates.has(d)) missing.push(d);
      const e = dget(d), r = tachoDay(d), cash = dayExpTotal(d);
      const mine = (v) => `<b>${esc(v)}</b>`, theirs = (v) => esc(v);
      const s = e.start ? mine(e.start) : r ? theirs(fixLabel(r.startFix)) : '';
      const f = e.finish ? mine(e.finish) : r ? theirs(fixLabel(r.endFix)) : '';
      const stops = fmtStops(e.stops) ? mine(fmtStops(e.stops)) : r && r.drops.length ? theirs(fmtStops(gpsStops(r))) : '';
      const lines = [s || f ? `${s || '?'} → ${f || '?'}` : '', stops].filter(Boolean).join('<br>');
      const cls = ['cal-d', d.slice(0, 7) !== calMonth ? 'other' : '', d === calSel ? 'sel' : '', d === today ? 'today' : '', inWeek(d) ? 'wk' : ''].join(' ');
      html += `<button type="button" class="${cls}" data-date="${d}"><span class="n">${+d.slice(8)}${r ? '<i class="dot" title="Tacho activity"></i>' : ''}` +
        `${cash ? `<span class="cash">£${cash.toFixed(cash % 1 ? 2 : 0)}</span>` : ''}</span><span class="t">${lines}</span></button>`;
    }
    $('#cal').innerHTML = html;
    $$('#cal [data-date]').forEach((b) => b.onclick = () => selectCalDay(b.dataset.date));
    // Load the visible weeks' expenses once, then draw again with the £ badges.
    if (missing.length && !calLoading) { calLoading = true; Promise.all(missing.map(weekState)).then(() => { calLoading = false; renderCalGrid(); }); }
  }
  function fillCalEditor() {
    const e = dget(calSel), r = tachoDay(calSel);
    const set = (sel, v) => { const el = $(sel); if (document.activeElement !== el && el.value !== v) el.value = v; };
    set('#calStart', e.start || ''); set('#calFinish', e.finish || '');
    $('#calStart').placeholder = (r && fixLabel(r.startFix)) || 'e.g. Scorrier';
    $('#calFinish').placeholder = (r && fixLabel(r.endFix)) || 'e.g. Kepak Merthyr';
    $('#calTacho').textContent = !card ? 'Load your .ddd file to see the tacho for this day. You can still write the diary now.'
      : !r ? 'No tacho activity on this day.'
        : `From the tacho: ${r.startTime}–${r.finishTime}` +
          `${fixLabel(r.startFix) || fixLabel(r.endFix) ? ` · ${fixLabel(r.startFix) || '?'} → ${fixLabel(r.endFix) || '?'}` : ''}` +
          ` · driving ${r.driving}${r.drops.length ? ` · GPS drops: ${fmtStops(gpsStops(r))}` : ''}${r.stops.length ? ` · stops with work: ${r.stops.map((x) => x.label).join(', ')}` : ''}`;
  }
  function selectCalDay(d) { calSel = d; calMonth = d.slice(0, 7); renderCal(); }
  function renderCal() {
    if (!calMonth) return;
    renderCalGrid();
    const wd = DAYS[dayIdx(calSel)];
    $('#calDate').textContent = `${wd} ${fmtLong(calSel)}`;
    fillCalEditor();
    const ed = stopsEditor($('#calStops'), calSel);
    const freq = frequentStops();
    $('#calChips').innerHTML = freq.map((s) => `<button type="button" class="chip" data-type="${s.type}">${s.type === 'drop' ? '' : STOP_TYPES[s.type] + ' · '}${esc(s.name)}</button>`).join('')
      || '<span class="small muted">Names you add show up here for next time.</span>';
    $$('#calChips .chip').forEach((c, n) => {
      const s = freq[n];
      c.onclick = () => ed.add({ type: s.type, name: s.name, ...(isFinite(s.lat) ? { lat: s.lat, lon: s.lon } : {}) });
      onHold(c, () => chipMenu(s));
    });
    dayExpensesEditor($('#calExp'), calSel);
  }
  function setupCal() {
    calSel = todayKey(); calMonth = calSel.slice(0, 7);
    const move = (n) => { const [y, m] = calMonth.split('-').map(Number); calMonth = new Date(Date.UTC(y, m - 1 + n, 1)).toISOString().slice(0, 7); renderCalGrid(); };
    $('#calPrev').onclick = () => move(-1);
    $('#calNext').onclick = () => move(1);
    $('#calToday').onclick = () => selectCalDay(todayKey());
    const bind = (sel, field, fixOf) => {
      const el = $(sel);
      el.oninput = () => setDiary(calSel, field, el.value);
      el.onchange = () => {   // naming a place in the diary also teaches it for that GPS spot
        const r = tachoDay(calSel), fix = r && fixOf(r);
        if (profile.learn !== 'no' && fix && fix.exact && el.value.trim()) { learnPlace(fix.pos, el.value.trim()); weekCache.clear(); renderCalGrid(); refreshAuto(); }
      };
    };
    $('#calStartLoc').onclick = () => locatePicker('📍 Where did you start?', (name) => { $('#calStart').value = name; setDiary(calSel, 'start', name); });
    $('#calFinishLoc').onclick = () => locatePicker('📍 Where did you finish?', (name) => { $('#calFinish').value = name; setDiary(calSel, 'finish', name); });
    bind('#calStart', 'start', (r) => r.startFix);
    bind('#calFinish', 'finish', (r) => r.endFix);
    $('#calCopyTacho').onclick = () => {
      const r = tachoDay(calSel);
      if (!r) return alert('The tacho has nothing for this day.');
      if (fixLabel(r.startFix)) setDiary(calSel, 'start', fixLabel(r.startFix));
      if (fixLabel(r.endFix)) setDiary(calSel, 'finish', fixLabel(r.endFix));
      if (r.drops.length && !(dget(calSel).stops || []).length) setDiary(calSel, 'stops', gpsStops(r));
      renderCal();
    };
    $('#calClear').onclick = () => {
      if (!diary[calSel] || !confirm('Clear the places and drops for this day? Expenses are kept.')) return;
      delete diary[calSel]; LS.set('diary', diary); renderCal(); if (inWeek(calSel)) { saveWeek(); refreshAuto(); renderDays(); }
    };
    $('#calOpenWeek').onclick = () => {
      const s = sundayOfKey(calSel), sel = $('#weekSel');
      if (![...sel.options].some((o) => o.value === s)) sel.add(new Option(`w/c Sunday ${fmtLong(s)}`, s), 0);
      sel.value = s; selectWeek(s); showTab('sheet');
    };
    updatePlaceList();
  }

  // ---- downloaded? ----------------------------------------------------------------------------------
  let toastT;
  function toast(msg) {
    const t = $('#toast');
    t.textContent = msg; t.classList.add('show');
    clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('show'), 4000);
  }
  function markDone(how) {
    ws.done = { at: Date.now(), how, file: fileName() };
    clearTimeout(saveT); idb.set('week:' + weekKey, ws);
    showDone(); annotateWeeks();
  }
  function showDone() {
    const el = $('#doneState');
    if (!el || !ws) return;
    const d = ws.done;
    if (!d) { el.className = 'done-state'; el.textContent = 'Not downloaded yet'; el.title = ''; return; }
    const when = new Date(d.at).toLocaleString('en-GB', { timeZone: 'Europe/London', weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
    const changed = ws.editedAt && ws.editedAt > d.at;
    el.className = 'done-state ' + (changed ? 'warn' : 'ok');
    el.textContent = `${changed ? '⚠' : '✓'} ${d.how === 'shared' ? 'Shared' : 'Downloaded'} ${when}${changed ? ' · changed since' : ''}`;
    el.title = d.file + (changed ? ' — you changed this week after downloading it; download it again.' : '');
  }
  // Tick the weeks you've already sent in the week list.
  async function annotateWeeks() {
    const done = new Set();
    for (const [k, v] of await idb.entries()) if (String(k).startsWith('week:') && v && v.done) done.add(String(k).slice(5));
    for (const [k, v] of weekStates) if (v.done) done.add(k);
    for (const o of $('#weekSel').options) {
      o.dataset.base = o.dataset.base || o.textContent;
      o.textContent = o.dataset.base + (done.has(o.value) ? '  ✓ sent' : '');
    }
  }

  // ---- small UI pieces: sheets and press-and-hold ---------------------------------------------------
  function sheet(html) {
    const ov = document.createElement('div');
    ov.className = 'sheet-ov';
    ov.innerHTML = `<div class="sheet" role="dialog" aria-modal="true">${html}</div>`;
    document.body.appendChild(ov);
    const el = ov.firstElementChild;
    const esc_ = (e) => { if (e.key === 'Escape') el.close(); };
    el.close = () => { ov.remove(); document.removeEventListener('keydown', esc_); };
    ov.addEventListener('click', (e) => { if (e.target === ov || e.target.closest('[data-close]')) el.close(); });
    document.addEventListener('keydown', esc_);
    return el;
  }
  // Long press (or right-click) runs fn; the click that ends the press is swallowed.
  function onHold(el, fn) {
    let t = null, sx = 0, sy = 0;
    const cancel = () => { if (t) { clearTimeout(t); t = null; } };
    el.addEventListener('pointerdown', (e) => {
      sx = e.clientX; sy = e.clientY;
      t = setTimeout(() => { t = null; el.dataset.held = '1'; if (navigator.vibrate) navigator.vibrate(25); fn(); }, 550);
    });
    el.addEventListener('pointermove', (e) => { if (Math.hypot(e.clientX - sx, e.clientY - sy) > 10) cancel(); });
    ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) => el.addEventListener(ev, cancel));
    el.addEventListener('contextmenu', (e) => { e.preventDefault(); cancel(); el.dataset.held = '1'; fn(); });
    el.addEventListener('click', (e) => { if (el.dataset.held) { e.stopImmediatePropagation(); e.preventDefault(); delete el.dataset.held; } }, true);
  }
  function viewAttachment(att) {
    const url = URL.createObjectURL(new Blob([att.data], { type: att.mime }));
    if (att.kind === 'pdf') { window.open(url, '_blank'); return; }
    const sh = sheet(`<img src="${url}" alt="Receipt" style="max-width:100%;max-height:75vh;display:block;margin:0 auto;border-radius:8px">
      <div class="actions" style="margin-top:10px;justify-content:flex-end"><button class="btn small" data-close>Close</button></div>`);
    sh.classList.add('wide');
  }

  // ---- starred places: exact spots (gate entrances) you can navigate to ---------------------------------
  let lastPos = null, map = null, mapLayer = null, mapPicking = false;
  const saveStars = () => { LS.set('stars', stars); updatePlaceList(); if ($('#tab-places').classList.contains('on')) renderPlacesTab(); };
  function addStar(p) {
    const same = stars.find((s) => s.name.toLowerCase() === (p.name || '').toLowerCase() && Geo.distM(s, p) < 25);
    if (same) Object.assign(same, p); else stars.push({ id: uid(), note: '', ...p });
    saveStars();
  }
  function navButtons(p) {
    const l = Geo.navLinks(p);
    return `<a class="btn small primary" href="${l.google}" target="_blank" rel="noopener">Google Maps</a>
      <a class="btn small" href="${l.waze}" target="_blank" rel="noopener">Waze</a>
      ${l.tomtom ? `<a class="btn small" href="${l.tomtom}">${Geo.isIOS ? 'TomTom' : 'TomTom / other'}</a>` : ''}
      <button type="button" class="btn small" data-copy="${l.ll}">Copy</button>`;
  }
  function bindCopy(root) {
    $$('[data-copy]', root).forEach((b) => b.onclick = async () => {
      try { await navigator.clipboard.writeText(b.dataset.copy); toast('Copied ' + b.dataset.copy); } catch { prompt('Copy these coordinates:', b.dataset.copy); }
    });
  }
  function starEditor(p, onSaved) {
    const cur = { name: '', note: '', ...p };
    const sh = sheet(`<h3>${p.id ? 'Edit starred place' : '⭐ Star a place'}</h3>
      <div class="grid2">
        <label class="f">Name<input data-f="name" value="${esc(cur.name)}" placeholder="e.g. Sainsbury's Paignton – goods in"></label>
        <label class="f">Note (gate, bay, phone…)<input data-f="note" value="${esc(cur.note)}" placeholder="e.g. Gate 2 on Torquay Rd, ring bell"></label>
      </div>
      <label class="f" style="margin-top:10px">Location: paste a Google Maps link or coordinates<input data-f="paste" placeholder="https://www.google.com/maps/… or 50.4362, -3.5699"></label>
      <div class="small muted" data-f="where" style="margin-top:6px"></div>
      <div class="actions" style="margin-top:8px"><button type="button" class="btn small" data-f="here">📍 Use where I am now</button>${p.id ? '<button type="button" class="btn small" data-f="del">Delete</button>' : ''}</div>
      <div class="actions" style="margin-top:14px;justify-content:flex-end"><button type="button" class="btn small" data-close>Cancel</button><button type="button" class="btn small primary" data-f="save">Save</button></div>`);
    const where = () => {
      $('[data-f=where]', sh).innerHTML = isFinite(cur.lat) ? `${cur.lat.toFixed(6)}, ${cur.lon.toFixed(6)} · <a href="${Geo.navLinks(cur).view}" target="_blank" rel="noopener">check on Google Maps</a>`
        : 'No location yet: paste a link or use where you are.';
    };
    where();
    $('[data-f=paste]', sh).oninput = (e) => {
      const v = e.target.value, c = Geo.parseCoords(v);
      if (c) { cur.lat = c.lat; cur.lon = c.lon; if (c.name && !$('[data-f=name]', sh).value) $('[data-f=name]', sh).value = c.name; where(); }
      else if (Geo.isShortLink(v)) $('[data-f=where]', sh).textContent = 'Short "maps.app.goo.gl" links can\'t be read. In Google Maps, press and hold the exact spot: the coordinates appear at the top. Copy and paste those.';
    };
    $('[data-f=here]', sh).onclick = async (e) => {
      e.target.textContent = 'Finding you…';
      try { const pos = await Geo.here(); lastPos = pos; cur.lat = pos.lat; cur.lon = pos.lon; where(); e.target.textContent = `📍 Got it (±${Math.round(pos.acc)} m)`; }
      catch (err) { alert(err.message); e.target.textContent = '📍 Use where I am now'; }
    };
    const del = $('[data-f=del]', sh);
    if (del) del.onclick = () => { if (!confirm('Delete this starred place?')) return; stars = stars.filter((s) => s.id !== p.id); saveStars(); sh.close(); };
    $('[data-f=save]', sh).onclick = () => {
      cur.name = $('[data-f=name]', sh).value.trim(); cur.note = $('[data-f=note]', sh).value.trim();
      if (!cur.name) return alert('Give it a name.');
      if (!isFinite(cur.lat)) return alert('Add the location: paste a link or coordinates, or use where you are.');
      if (p.id) Object.assign(stars.find((s) => s.id === p.id), cur); else addStar(cur);
      saveStars(); sh.close(); toast('⭐ Saved ' + cur.name);
      if (onSaved) onSaved(cur);
    };
    setTimeout(() => $(p.name ? '[data-f=note]' : '[data-f=name]', sh).focus(), 50);
  }

  // ---- 📍 "where am I?" picker: starred spots, saved places, shops and depots nearby, the town -----------
  async function locatePicker(title, onPick) {
    const sh = sheet(`<h3>${esc(title)}</h3>
      <div class="small muted" data-p="status">Getting your location…</div>
      <div class="pick-list" data-p="list"></div>
      <div class="inp-row" style="margin-top:10px"><input data-p="own" list="placeNames" placeholder="Or type a name"><button type="button" class="btn small primary" data-p="use">Use</button></div>
      <label class="check small" style="margin-top:10px"><input type="checkbox" data-p="star"> ⭐ Also star this exact spot (for sat-nav)</label>
      <div class="actions" style="margin-top:12px;justify-content:flex-end"><button type="button" class="btn small" data-close>Cancel</button></div>`);
    let pos = null;
    const items = [], seen = new Set();
    const pick = (name, at) => {
      name = (name || '').trim();
      if (!name) return;
      const spot = at || pos;
      if ($('[data-p=star]', sh).checked && spot) addStar({ name, lat: spot.lat, lon: spot.lon });
      sh.close();
      onPick(name, spot ? { lat: spot.lat, lon: spot.lon } : null);
    };
    $('[data-p=use]', sh).onclick = () => pick($('[data-p=own]', sh).value);
    $('[data-p=own]', sh).onkeydown = (e) => { if (e.key === 'Enter') pick(e.target.value); };
    const draw = () => {
      $('[data-p=list]', sh).innerHTML = items.map((it, n) => `<button type="button" class="pick" data-n="${n}"><span>${esc(it.name)}</span><span class="small muted">${esc(it.sub)}</span></button>`).join('');
      $$('[data-p=list] .pick', sh).forEach((b) => b.onclick = () => { const it = items[+b.dataset.n]; pick(it.name, it.exact ? it : null); });
    };
    const add = (it) => { const k = it.name.toLowerCase(); if (seen.has(k)) return; seen.add(k); items.push(it); };
    try { pos = await Geo.here(); lastPos = pos; } catch (e) { $('[data-p=status]', sh).textContent = e.message + ' You can still type a name.'; return; }
    if (!document.body.contains(sh)) return;
    $('[data-p=status]', sh).textContent = `Found you (±${Math.round(pos.acc)} m). Pick the place, or type it:`;
    stars.map((s) => ({ s, d: Geo.distM(pos, s) })).filter((x) => x.d < 400).sort((a, b) => a.d - b.d)
      .forEach(({ s, d }) => add({ name: s.name, sub: `⭐ starred · ${Geo.fmtDist(d)}`, lat: s.lat, lon: s.lon, exact: true }));
    const sp = savedAt(pos);
    if (sp && sp.name) add({ name: sp.name, sub: 'saved place' });
    draw();
    $('[data-p=status]', sh).textContent += ' Looking for shops and depots nearby…';
    let busy = false;
    const [rev, near] = await Promise.all([Geo.reverse(pos.lat, pos.lon).catch(() => null), Geo.nearby(pos.lat, pos.lon).catch(() => { busy = true; return []; })]);
    if (!document.body.contains(sh)) return;
    const town = rev ? rev.town : '';
    for (const p of near) {
      const t = p.city || town;
      add({ name: t && !p.name.toLowerCase().includes(t.toLowerCase()) ? `${p.name} ${t}` : p.name, sub: `${p.kind || 'place'} · ${Geo.fmtDist(p.dist)}` });
    }
    if (town) add({ name: town, sub: `town${rev.postcode ? ' · ' + rev.postcode : ''}` });
    if (rev && rev.road && town) add({ name: `${rev.road}, ${town}`, sub: 'street' });
    $('[data-p=status]', sh).innerHTML = `Found you (±${Math.round(pos.acc)} m). Pick the place, or type it:` +
      (busy ? ' <span class="warn-txt">The map server is busy, so shops and depots nearby are missing.</span> <button type="button" class="btn small" data-p="retry">Try again</button>'
        : near.length ? '' : ' (nothing named nearby on the map)');
    draw();
    const retry = $('[data-p=retry]', sh);
    if (retry) retry.onclick = async () => {
      retry.textContent = 'Searching…'; retry.disabled = true;
      try {
        const more = await Geo.nearby(pos.lat, pos.lon);
        for (const p of more) { const t = p.city || town; add({ name: t && !p.name.toLowerCase().includes(t.toLowerCase()) ? `${p.name} ${t}` : p.name, sub: `${p.kind || 'place'} · ${Geo.fmtDist(p.dist)}` }); }
        items.sort((a, b) => (a.exact ? -1 : 0) - (b.exact ? -1 : 0));
        retry.remove(); draw();
      } catch { retry.textContent = 'Still busy, try again'; retry.disabled = false; }
    };
  }

  // ---- hold a suggestion chip: rename everywhere, hide, or star -------------------------------------------
  function chipMenu(s) {
    const sh = sheet(`<h3>${esc(s.name)}</h3>
      <div class="grid2">
        <label class="f">Type<select data-c="type">${Object.entries(STOP_TYPES).map(([k, v]) => `<option value="${k}" ${s.type === k ? 'selected' : ''}>${v}</option>`).join('')}</select></label>
        <label class="f">Name<input data-c="name" value="${esc(s.name)}"></label>
      </div>
      <p class="small muted">"Save everywhere" changes it in every day of your diary that uses it.</p>
      <div class="actions" style="justify-content:flex-end">
        <button type="button" class="btn small" data-c="hide">Remove from list</button>
        <button type="button" class="btn small" data-c="star">⭐ Star it</button>
        <button type="button" class="btn small" data-close>Cancel</button>
        <button type="button" class="btn small primary" data-c="save">Save everywhere</button></div>`);
    $('[data-c=save]', sh).onclick = () => {
      const name = $('[data-c=name]', sh).value.trim(), type = $('[data-c=type]', sh).value;
      if (!name) return;
      let n = 0;
      for (const e of Object.values(diary)) for (const x of e.stops || []) {
        if (x.type === s.type && (x.name || '').trim().toLowerCase() === s.name.toLowerCase()) { x.name = name; x.type = type; n++; }
      }
      LS.set('diary', diary); sh.close(); renderCal(); if (ws) refreshAuto(); updatePlaceList();
      toast(`Changed ${n} entr${n === 1 ? 'y' : 'ies'}`);
    };
    $('[data-c=hide]', sh).onclick = () => {
      profile.hiddenStops = [...new Set([...(profile.hiddenStops || []), s.type + '|' + s.name.toLowerCase()])];
      LS.set('profile', profile); sh.close(); renderCal(); showHiddenCount();
      toast('Removed from the list (your diary is unchanged)');
    };
    $('[data-c=star]', sh).onclick = () => { sh.close(); starEditor({ name: s.name, ...(isFinite(s.lat) ? { lat: s.lat, lon: s.lon } : {}) }); };
  }
  function showHiddenCount() {
    const n = (profile.hiddenStops || []).length, b = $('#unhideStops');
    if (!b) return;
    b.classList.toggle('hidden', !n);
    b.textContent = `Show ${n} removed suggestion${n === 1 ? '' : 's'} again`;
  }

  // ---- Places tab ----------------------------------------------------------------------------------------
  function loadLeaflet() {
    if (window.L) return Promise.resolve();
    return new Promise((res, rej) => {
      const css = document.createElement('link');
      css.rel = 'stylesheet'; css.href = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
      document.head.appendChild(css);
      const js = document.createElement('script');
      js.src = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
      js.onload = res; js.onerror = () => rej(new Error('map unavailable offline'));
      document.head.appendChild(js);
    });
  }
  function renderStarList() {
    const q = ($('#starSearch').value || '').toLowerCase();
    const list = stars.filter((s) => !q || (s.name + ' ' + s.note).toLowerCase().includes(q))
      .map((s) => ({ s, d: lastPos ? Geo.distM(lastPos, s) : null }))
      .sort((a, b) => (a.d !== null ? a.d - b.d : a.s.name.localeCompare(b.s.name)));
    $('#starList').innerHTML = list.map(({ s, d }) => `<div class="star" data-id="${s.id}">
        <div class="star-main"><b>⭐ ${esc(s.name)}</b>${s.note ? `<div class="small">${esc(s.note)}</div>` : ''}
          <div class="small muted">${s.lat.toFixed(5)}, ${s.lon.toFixed(5)}${d !== null ? ' · ' + Geo.fmtDist(d) + ' away' : ''}</div></div>
        <div class="star-act">${navButtons(s)}<button type="button" class="btn small" data-edit>Edit</button><button type="button" class="btn small" data-show>Map</button></div></div>`).join('')
      || `<p class="small muted">${stars.length ? 'Nothing matches.' : 'No starred places yet. Star the exact gate of a drop with "Star where I am", a Google Maps link, or by picking it on the map.'}</p>`;
    bindCopy($('#starList'));
    $$('#starList .star').forEach((el) => {
      const s = stars.find((x) => x.id === el.dataset.id);
      $('[data-edit]', el).onclick = () => starEditor(s);
      $('[data-show]', el).onclick = () => { if (map) { map.setView([s.lat, s.lon], 17); $('#map').scrollIntoView({ behavior: 'smooth', block: 'center' }); } };
    });
  }
  async function renderMap() {
    try { await loadLeaflet(); } catch { $('#map').innerHTML = '<p class="small muted" style="padding:12px">The map needs an internet connection.</p>'; return; }
    if (!map) {
      map = L.map('map', { zoomControl: true }).setView([52.4, -2.5], 6);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
      mapLayer = L.layerGroup().addTo(map);
      map.on('click', (e) => {
        if (!mapPicking) return;
        setPicking(false);
        starEditor({ lat: e.latlng.lat, lon: e.latlng.lng });
      });
      const pts = [...stars, ...places].map((p) => [p.lat, p.lon]);
      if (pts.length) map.fitBounds(pts, { padding: [30, 30], maxZoom: 14 });
    }
    setTimeout(() => map.invalidateSize(), 50);
    mapLayer.clearLayers();
    for (const p of places) {
      L.circle([p.lat, p.lon], { radius: p.radius || 500, color: p.base ? '#1d7a46' : '#1f4fbf', weight: 1.5, fillOpacity: 0.12 })
        .bindTooltip(p.name || (p.base ? 'Base' : 'Saved place')).addTo(mapLayer);
    }
    for (const s of stars) {
      const m = L.marker([s.lat, s.lon], { icon: L.divIcon({ className: 'star-pin', html: '⭐', iconSize: [26, 26], iconAnchor: [13, 13] }) });
      const box = document.createElement('div');
      box.innerHTML = `<b>${esc(s.name)}</b>${s.note ? `<div>${esc(s.note)}</div>` : ''}<div class="actions" style="margin-top:6px">${navButtons(s)}<button type="button" class="btn small" data-edit>Edit</button></div>`;
      bindCopy(box);
      $('[data-edit]', box).onclick = () => starEditor(s);
      m.bindPopup(box).addTo(mapLayer);
    }
    if (lastPos) L.circleMarker([lastPos.lat, lastPos.lon], { radius: 7, color: '#fff', weight: 2, fillColor: '#1f4fbf', fillOpacity: 1 }).bindTooltip('You').addTo(mapLayer);
  }
  function setPicking(on) {
    mapPicking = on;
    $('#starPick').classList.toggle('primary', on);
    $('#starPick').textContent = on ? 'Tap the map… (cancel)' : '🗺 Pick on map';
    $('#map').classList.toggle('picking', on);
  }
  function renderPlacesTab() { renderStarList(); renderMap(); renderPlaces(); }
  function setupPlaces() {
    $('#starSearch').oninput = renderStarList;
    $('#starHere').onclick = () => locatePicker('⭐ Star where I am: what is this place?', (name, pos) => {
      if (!pos) return alert('No location, so nothing was starred.');
      addStar({ name, lat: pos.lat, lon: pos.lon }); toast('⭐ Saved ' + name);
      const s = stars.find((x) => x.name === name && Geo.distM(x, pos) < 25);
      if (s) starEditor(s);   // straight into the note: gate, bay, phone…
    });
    $('#starPaste').onclick = () => {
      const sh = sheet(`<h3>Add from Google Maps</h3>
        <p class="small muted">In Google Maps, press and hold the exact spot (e.g. the gate), then copy the coordinates shown at the top, or use Share › Copy link and open it in the browser to get the long link. One place per line; you can paste several, like <i>Sainsbury's Paignton gate, 50.4362, -3.5699</i>.</p>
        <textarea data-s="txt" rows="5" placeholder="50.4362, -3.5699&#10;https://www.google.com/maps/place/…"></textarea>
        <div class="small muted" data-s="info" style="margin-top:6px"></div>
        <div class="actions" style="margin-top:10px;justify-content:flex-end"><button type="button" class="btn small" data-close>Cancel</button><button type="button" class="btn small primary" data-s="go">Next</button></div>`);
      const read = () => Geo.parseImport($('[data-s=txt]', sh).value, '');
      $('[data-s=txt]', sh).oninput = () => {
        const v = $('[data-s=txt]', sh).value, n = read().length;
        $('[data-s=info]', sh).textContent = Geo.isShortLink(v) && !n ? 'Short "maps.app.goo.gl" links can\'t be read here. Copy the coordinates instead (press and hold the spot in Google Maps).' : n ? `Found ${n} place${n > 1 ? 's' : ''}.` : '';
      };
      $('[data-s=go]', sh).onclick = () => {
        const list = read();
        if (!list.length) return alert('No coordinates found in that.');
        sh.close();
        if (list.length === 1) { const p = list[0]; starEditor({ name: p.name === 'Imported place' ? '' : p.name, note: p.note, lat: p.lat, lon: p.lon }); return; }
        list.forEach(addStar); toast(`⭐ Added ${list.length} places`);
      };
    };
    $('#starPick').onclick = () => setPicking(!mapPicking);
    const dl = (txt, type, ext) => download(new Blob([txt], { type }), `starred-places-${todayKey()}.${ext}`);
    $('#starGpx').onclick = () => dl(Geo.toGPX(stars), 'application/gpx+xml', 'gpx');
    $('#starKml').onclick = () => dl(Geo.toKML(stars), 'application/vnd.google-earth.kml+xml', 'kml');
    $('#starCsv').onclick = () => dl(Geo.toCSV(stars), 'text/csv', 'csv');
    $('#starImport').onchange = async (e) => {
      const f = e.target.files[0]; if (!f) return;
      const list = Geo.parseImport(await f.text(), f.name);
      e.target.value = '';
      if (!list.length) return alert('No places found in that file.');
      list.forEach(addStar); toast(`⭐ Imported ${list.length} places`);
    };
    $('#unhideStops').onclick = () => { delete profile.hiddenStops; LS.set('profile', profile); showHiddenCount(); renderCal(); toast('Suggestions are back'); };
    showHiddenCount();
  }

  // ---- tabs -------------------------------------------------------------------------------------
  function showTab(t) {
    if (!['sheet', 'diary', 'places', 'me'].includes(t)) t = 'sheet';
    $$('main.tab').forEach((m) => m.classList.toggle('on', m.id === 'tab-' + t));
    $$('nav.tabs [data-tab]').forEach((b) => b.classList.toggle('on', b.dataset.tab === t));
    try { localStorage.setItem('tt.tab', t); } catch { /* ignore */ }
    if (location.hash !== '#' + t) history.replaceState(null, '', '#' + t);
    if (t === 'diary') renderCal();
    if (t === 'places') renderPlacesTab();
    if (t === 'sheet') schedulePdf();
    window.scrollTo(0, 0);
  }
  function setupTabs() {
    $$('nav.tabs [data-tab]').forEach((b) => b.onclick = () => showTab(b.dataset.tab));
    $$('a.tablink').forEach((a) => a.onclick = (e) => { e.preventDefault(); showTab(a.getAttribute('href').slice(1)); });
    window.addEventListener('hashchange', () => showTab(location.hash.slice(1)));
    let saved = 'sheet'; try { saved = localStorage.getItem('tt.tab') || 'sheet'; } catch { /* ignore */ }
    showTab(location.hash.slice(1) || saved);
  }

  // ---- storage: keep it, back it up --------------------------------------------------------------
  async function setupStorage() {
    const el = $('#storageState');
    let kept = false;
    try {
      if (navigator.storage && navigator.storage.persist) kept = (await navigator.storage.persisted()) || (await navigator.storage.persist());
    } catch { /* not supported */ }
    let used = '';
    try { const est = await navigator.storage.estimate(); used = ` (${(est.usage / 1048576).toFixed(1)} MB used)`; } catch { /* ignore */ }
    el.innerHTML = kept ? `✓ Saved on this device${used}. The browser has agreed not to clear it automatically.`
      : `Saved on this device${used}. The browser hasn't promised to keep it forever, so download a copy now and then.`;
  }
  const stripPhotos = (w) => ({ ...w, expenses: (w.expenses || []).map((e) => { const { att, ...rest } = e; return att ? { ...rest, photo: att.name } : rest; }), other: [] });
  async function exportAll() {
    const weeks = {};
    for (const [k, v] of await idb.entries()) if (String(k).startsWith('week:')) weeks[k] = stripPhotos(v);
    const data = { app: 'tacho-timesheet', version: 3, exported: new Date().toISOString(), profile, places, stars, diary, geo, weeks };
    download(new Blob([JSON.stringify(data, null, 1)], { type: 'application/json' }), `tacho-timesheet-data-${todayKey()}.json`);
  }
  async function importAll(file) {
    const j = JSON.parse(await file.text());
    // Merge, so restoring never wipes a signature, places or entries already on this device.
    if (j.profile) { profile = { ...profile, ...j.profile }; LS.set('profile', profile); }
    if (j.places) {
      for (const p of j.places) {
        const same = places.find((q) => Week.distKm(q, p) < 0.2);
        if (same) Object.assign(same, p); else places.push(p);
      }
      const b = j.places.find((p) => p.base);
      if (b) places.forEach((q) => { q.base = Week.distKm(q, b) < 0.2; });
      LS.set('places', places);
    }
    if (j.diary) {
      for (const [d, v] of Object.entries(j.diary)) diary[d] = { ...normalizeEntry(v), ...dget(d) };
      LS.set('diary', diary);
    }
    if (j.geo) { Object.assign(geo, j.geo); LS.set('geo', geo); }
    if (j.stars) j.stars.forEach(addStar);
    for (const [k, v] of Object.entries(j.weeks || {})) {
      const cur = await idb.get(k);
      if (!cur) { await idb.set(k, v); continue; }
      cur.days = cur.days.map((o, i) => ({ ...(v.days && v.days[i]), ...o }));
      cur.foot = { ...v.foot, ...cur.foot };
      for (const e of v.expenses || []) if (!cur.expenses.some((x) => x.id === e.id)) cur.expenses.push(e);
      await idb.set(k, cur);
    }
  }

  // ---- email text ---------------------------------------------------------------------------
  const DEFAULT_EMAIL = 'Hello,\n\nPlease find attached my timesheet for the week commencing {weekCommencing} (vehicle {vehicle}).\n\n' +
    'Days worked: {days}. Nights out: {nights}. Expenses: £{expenses}.\n\nKind regards,\n{name}';
  function emailText() {
    if (!ws) return '';
    const d = buildData(), days = d.p1.days;
    const list = days.map((x, i) => x.startTime ? `${DAYS[i].slice(0, 3)} ${fmtShort(Week.addDays(weekKey, i))}: ${x.startTime}-${x.finishTime}` +
      `${x.startPlace || x.finishPlace ? ` ${x.startPlace || '?'} to ${x.finishPlace || '?'}` : ''}${x.drops ? ` (${x.drops})` : ''}` : '').filter(Boolean).join('\n');
    const id = card && card.identification;
    const vals = {
      name: footVal('name') || '', firstName: id ? id.firstNames.split(' ')[0] : (footVal('name') || '').split(' ').pop(),
      weekCommencing: fmtShort(weekKey), weekEnding: fmtShort(Week.addDays(weekKey, 6)), vehicle: footVal('vehicle') || '',
      days: days.filter((x) => x.startTime || x.finishTime).length, nights: d.p2.totals.uk + d.p2.totals.eu,
      expenses: (Number(d.p2.totals.total) || 0).toFixed(2), daysList: list, file: fileName(),
    };
    return (profile.emailTpl || DEFAULT_EMAIL).replace(/\{(\w+)\}/g, (m, k) => (k in vals ? vals[k] : m));
  }
  function updateEmail() { const o = $('#emailOut'); if (o) o.value = emailText(); }
  function setupEmail() {
    const t = $('#emailTpl');
    t.value = profile.emailTpl || DEFAULT_EMAIL;
    t.oninput = () => { profile.emailTpl = t.value; LS.set('profile', profile); updateEmail(); };
    $('#emailReset').onclick = () => { delete profile.emailTpl; LS.set('profile', profile); t.value = DEFAULT_EMAIL; updateEmail(); };
    $('#emailCopy').onclick = async () => {
      const txt = emailText();
      try { await navigator.clipboard.writeText(txt); } catch { const o = $('#emailOut'); o.select(); document.execCommand('copy'); }
      $('#emailCopy').textContent = 'Copied ✓';
      setTimeout(() => { $('#emailCopy').textContent = 'Copy email'; }, 1500);
    };
  }

  // ---- PDF ----------------------------------------------------------------------------------
  function buildData() {
    const days = [0, 1, 2, 3, 4, 5, 6].map((i) => {
      const o = {}; for (const k of DAY_KEYS) o[k] = dayVal(i, k) || ''; return o;
    });
    const n2 = (v) => { const x = parseFloat(v); return isNaN(x) ? 0 : x; };
    const rows = days.map((d) => ({ place: d.stayed, uk: d.nightOut === 'UK', eu: d.nightOut === 'EU', parking: 0, tolls: 0, market: 0, vat: 0, notes: { parking: [], tolls: [], market: [] } }));
    const exps = ws.expenses.filter((e) => n2(e.amount) || e.note);
    for (const e of exps) {
      const r = rows[+e.day]; if (!r) continue;
      const col = e.type === 'food' ? 'market' : e.type;   // the form has no food column
      r[col] += n2(e.amount); r.vat += n2(e.vat);
      const note = e.type === 'food' ? ('Food ' + (e.note || '')).trim() : e.note;
      if (note) r.notes[col].push(note);
    }
    const blank = (v) => v ? v : '';
    const out = rows.map((r) => ({
      place: r.place, uk: r.uk, eu: r.eu,
      parking: blank(r.parking), parkingNote: r.notes.parking.join('/'),
      tolls: blank(r.tolls), tollsNote: r.notes.tolls.join('/'),
      market: blank(r.market), marketNote: r.notes.market.join('/'),
      vat: blank(r.vat), total: blank(r.parking + r.tolls + r.market),
    }));
    const sum = (k) => rows.reduce((a, r) => a + r[k], 0);
    const totals = {
      uk: rows.filter((r) => r.uk).length, eu: rows.filter((r) => r.eu).length,
      parking: blank(sum('parking')), tolls: blank(sum('tolls')), market: blank(sum('market')), vat: blank(sum('vat')),
      total: blank(sum('parking') + sum('tolls') + sum('market')),
    };
    const f = (k) => footVal(k) || '';
    const attachments = [];
    ws.expenses.filter((e) => e.att).sort((a, b) => a.day - b.day).forEach((e) => attachments.push({
      kind: e.att.kind, mime: e.att.mime, bytes: e.att.data, name: e.att.name,
      caption: `${DAYS[+e.day]} ${fmtShort(Week.addDays(weekKey, +e.day))} - ${TYPES[e.type]}${e.note ? ' (' + e.note + ')' : ''}${n2(e.amount) ? ' - £' + n2(e.amount).toFixed(2) : ''}`,
    }));
    ws.other.forEach((a) => attachments.push({ kind: a.kind, mime: a.mime, bytes: a.data, name: a.name, caption: a.caption || '' }));
    return {
      p1: {
        name: f('name'), weekCommencing: f('weekCommencing'), days,
        totalWeekdays: f('totalWeekdays'), totalWeekendDays: f('totalWeekendDays'), away24: f('away24'), declaration: f('declaration'),
        signature: profile.signature || null,
      },
      p2: {
        nameLine: f('nameLine'), addr1: f('addr1'), addr2: f('addr2'), ni: f('ni'), vehicle: f('vehicle'),
        signedDate: f('signedDate'), weDate: f('weDate'), signature: profile.signature || null, rows: out, totals,
      },
      attachments,
    };
  }
  const fileName = () => { const { y, m, d } = parts(weekKey); return `TC_timesheet_${d}_${m}_${String(y).slice(2)}.pdf`; };
  let pdfT, pdfUrl, building = false, again = false;
  function schedulePdf() { clearTimeout(pdfT); pdfT = setTimeout(renderPdf, 500); }
  async function renderPdf() {
    if (!ws) return;
    updateEmail();
    if (building) { again = true; return; }
    building = true;
    try {
      const bytes = await TimesheetPDF.build(buildData(), { page2: footVal('page2') !== 'no' });
      const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
      if (!document.body.classList.contains('no-pdf-viewer')) $('#pdfFrame').src = url + '#view=FitH';
      if (pdfUrl) setTimeout(((u) => () => URL.revokeObjectURL(u))(pdfUrl), 3000);
      pdfUrl = url;
    } catch (e) { console.error(e); setStatus('PDF error: ' + e.message); }
    building = false;
    if (again) { again = false; renderPdf(); }
  }
  function download(blob, name) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }
  function setStatus(t) { $('#status').textContent = t; }

  // ---- wiring ---------------------------------------------------------------------------------
  async function onFile(f) { if (f) await loadCard(await f.arrayBuffer(), f.name, true); }
  function init() {
    $('#fileInput').onchange = (e) => onFile(e.target.files[0]);
    const dz = $('#dropZone');
    dz.onclick = () => $('#fileInput').click();
    ['dragenter', 'dragover'].forEach((t) => document.addEventListener(t, (e) => { e.preventDefault(); dz.classList.add('over'); }));
    ['dragleave', 'drop'].forEach((t) => document.addEventListener(t, (e) => { e.preventDefault(); dz.classList.remove('over'); }));
    document.addEventListener('drop', (e) => {
      const f = e.dataTransfer.files[0];
      if (f && /\.(ddd|c1b|esm|tgd|v1b)$/i.test(f.name)) onFile(f);
    });
    $('#weekSel').onchange = (e) => selectWeek(e.target.value);
    $('#prevWeek').onclick = () => { const s = $('#weekSel'); if (s.selectedIndex < s.options.length - 1) { s.selectedIndex++; selectWeek(s.value); } };
    $('#nextWeek').onclick = () => { const s = $('#weekSel'); if (s.selectedIndex > 0) { s.selectedIndex--; selectWeek(s.value); } };
    $('#addExp').onclick = () => {
      const night = [0, 1, 2, 3, 4, 5, 6].find((i) => dayVal(i, 'nightOut'));
      ws.expenses.push({ id: uid(), day: night ?? 0, type: 'parking', note: '', amount: '', vat: '' });
      saveWeek(); renderExpenses();
    };
    $('#attachOther').onchange = async (e) => {
      for (const f of e.target.files) { try { ws.other.push(await readAttachment(f)); } catch (err) { alert(err.message); } }
      e.target.value = ''; saveWeek(); renderOther(); schedulePdf();
    };
    $('#download').onclick = async () => {
      setStatus('Building PDF…');
      const bytes = await TimesheetPDF.build(buildData(), { page2: footVal('page2') !== 'no' });
      download(new Blob([bytes], { type: 'application/pdf' }), fileName());
      setStatus('');
      markDone('downloaded');
      toast(`✓ Saved ${fileName()} to your Downloads`);
    };
    $('#share').onclick = async () => {
      const bytes = await TimesheetPDF.build(buildData(), { page2: footVal('page2') !== 'no' });
      const file = new File([bytes], fileName(), { type: 'application/pdf' });
      try {
        await navigator.share({ files: [file], title: fileName(), text: emailText() });
        markDone('shared'); toast('✓ Shared ' + fileName());
      } catch (e) { if (e.name !== 'AbortError') alert('Sharing failed: ' + e.message); }
    };
    $('#openPreview').onclick = () => { if (pdfUrl) window.open(pdfUrl, '_blank'); };
    // Phones can't show a PDF inside the page: offer "Open preview" and "Share" instead.
    if (navigator.pdfViewerEnabled === false || /Android|iPhone|iPad/i.test(navigator.userAgent)) {
      document.body.classList.add('no-pdf-viewer'); $('#openPreview').classList.remove('hidden');
    }
    try { if (navigator.canShare && navigator.canShare({ files: [new File(['x'], 'x.pdf', { type: 'application/pdf' })] })) $('#share').classList.remove('hidden'); } catch { /* no file sharing */ }
    if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
      // When a new version has installed, reload once so you're never stuck on the old one.
      const hadOne = !!navigator.serviceWorker.controller;
      let reloaded = false;
      navigator.serviceWorker.addEventListener('controllerchange', () => { if (hadOne && !reloaded) { reloaded = true; location.reload(); } });
      navigator.serviceWorker.register('sw.js').then((r) => r.update()).catch((e) => console.warn('offline mode unavailable', e));
    }
    $('#downloadBlank').onclick = async () => download(new Blob([await TimesheetPDF.build({})], { type: 'application/pdf' }), 'TC_timesheet_blank.pdf');
    setupSignature(); setupSettings(); setupFill(); setupCal(); setupEmail(); renderPlaces(); setupPlaces(); setupTabs(); setupStorage();
    window.TachoTimesheetDebug = { buildData, get card() { return card; } };
    idb.get('card').then((c) => c ? loadCard(c.bytes, c.name, false) : buildWeekList()).catch(() => buildWeekList());
  }
  init();
})();
