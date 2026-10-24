/* Receipt scanner.
 * Step 1 (crop): finds the paper in the photo, you fine-tune the corners (with a magnifier).
 * Step 2 (enhance): straightened result in Colour / Greyscale / B&W / Original, brightness and
 * contrast, extra parts for long receipts, and "Read total" (OCR) to pick out the amount and VAT.
 * Scanner.open(file) resolves to a JPEG File (with .scanInfo = { amount, vat, date } when read), or null. */
(function (root) {
  'use strict';

  const LS_MODE = 'tt.scanMode';
  const MODES = { colour: '🎨 Colour', grey: 'Greyscale', bw: 'B&W', original: 'Original' };

  // ---- image basics -------------------------------------------------------------------------------
  async function toCanvas(file, max = 2600) {
    const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
    const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
    return draw(bmp, Math.round(bmp.width * k), Math.round(bmp.height * k));
  }
  function draw(src, w, h) {
    const c = document.createElement('canvas');
    c.width = Math.max(1, w); c.height = Math.max(1, h);
    const x = c.getContext('2d'); x.imageSmoothingQuality = 'high'; x.drawImage(src, 0, 0, c.width, c.height);
    return c;
  }
  function rotate(c, dir = 1) {   // dir 1 = clockwise, -1 = anticlockwise
    const o = document.createElement('canvas');
    o.width = c.height; o.height = c.width;
    const x = o.getContext('2d');
    if (dir > 0) { x.translate(o.width, 0); x.rotate(Math.PI / 2); } else { x.translate(0, o.height); x.rotate(-Math.PI / 2); }
    x.drawImage(c, 0, 0);
    return o;
  }
  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const quadArea = (q) => Math.abs(q.reduce((s, p, i) => { const n = q[(i + 1) % 4]; return s + p.x * n.y - n.x * p.y; }, 0)) / 2;

  // ---- finding the receipt --------------------------------------------------------------------------
  // Bright blobs at a few thresholds; the winner is big and close to a rectangle.
  function detect(c) {
    const k = Math.min(1, 360 / Math.max(c.width, c.height));
    const w = Math.max(1, Math.round(c.width * k)), h = Math.max(1, Math.round(c.height * k));
    const d = draw(c, w, h).getContext('2d').getImageData(0, 0, w, h).data, n = w * h;
    const g = new Uint8Array(n), hist = new Array(256).fill(0);
    for (let i = 0; i < n; i++) { const v = (d[i * 4] * 0.299 + d[i * 4 + 1] * 0.587 + d[i * 4 + 2] * 0.114) | 0; g[i] = v; hist[v]++; }
    let sum = 0; for (let i = 0; i < 256; i++) sum += i * hist[i];
    let sumB = 0, wB = 0, best = 0, otsu = 128;
    for (let i = 0; i < 256; i++) {
      wB += hist[i]; if (!wB) continue;
      const wF = n - wB; if (!wF) break;
      sumB += i * hist[i];
      const v = wB * wF * (sumB / wB - (sum - sumB) / wF) ** 2;
      if (v > best) { best = v; otsu = i; }
    }
    let top = null;
    for (const t of [otsu, otsu + 18, otsu - 18, otsu + 36]) {
      const b = biggestBlob(g, w, h, Math.max(20, Math.min(240, t)));
      if (!b || b.size < n * 0.06 || b.size > n * 0.97) continue;
      const q = [b.tl, b.tr, b.br, b.bl].map(([x, y]) => ({ x, y }));
      const rect = b.size / Math.max(1, quadArea(q));   // 1 = perfect quadrilateral
      const score = b.size * Math.min(1, rect) ** 3;
      if (!top || score > top.score) top = { q, score };
    }
    if (!top) return fullFrame(c, 0.06);
    return top.q.map((p) => ({ x: (p.x + 0.5) / k, y: (p.y + 0.5) / k }));
  }
  function biggestBlob(g, w, h, t) {
    const n = w * h, lab = new Uint8Array(n), stack = new Int32Array(n);
    let top = null;
    for (let i = 0; i < n; i++) {
      if (lab[i] || g[i] <= t) continue;
      let sp = 0; stack[sp++] = i; lab[i] = 1;
      const b = { size: 0, minS: Infinity, maxS: -Infinity, minD: Infinity, maxD: -Infinity };
      while (sp) {
        const p = stack[--sp], x = p % w, y = (p / w) | 0;
        b.size++;
        const S = x + y, D = x - y;
        if (S < b.minS) { b.minS = S; b.tl = [x, y]; }
        if (S > b.maxS) { b.maxS = S; b.br = [x, y]; }
        if (D > b.maxD) { b.maxD = D; b.tr = [x, y]; }
        if (D < b.minD) { b.minD = D; b.bl = [x, y]; }
        if (x > 0 && !lab[p - 1] && g[p - 1] > t) { lab[p - 1] = 1; stack[sp++] = p - 1; }
        if (x < w - 1 && !lab[p + 1] && g[p + 1] > t) { lab[p + 1] = 1; stack[sp++] = p + 1; }
        if (y > 0 && !lab[p - w] && g[p - w] > t) { lab[p - w] = 1; stack[sp++] = p - w; }
        if (y < h - 1 && !lab[p + w] && g[p + w] > t) { lab[p + w] = 1; stack[sp++] = p + w; }
      }
      if (!top || b.size > top.size) top = b;
    }
    return top;
  }
  function fullFrame(c, m = 0) {
    const mx = c.width * m, my = c.height * m;
    return [{ x: mx, y: my }, { x: c.width - mx, y: my }, { x: c.width - mx, y: c.height - my }, { x: mx, y: c.height - my }];
  }

  // ---- straightening (perspective warp) ---------------------------------------------------------------
  function homography(rect, quad) {
    const A = [], B = [];
    for (let i = 0; i < 4; i++) {
      const { x: u, y: v } = rect[i], { x, y } = quad[i];
      A.push([u, v, 1, 0, 0, 0, -u * x, -v * x]); B.push(x);
      A.push([0, 0, 0, u, v, 1, -u * y, -v * y]); B.push(y);
    }
    for (let c = 0; c < 8; c++) {
      let p = c;
      for (let r = c + 1; r < 8; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
      [A[c], A[p]] = [A[p], A[c]]; [B[c], B[p]] = [B[p], B[c]];
      for (let r = 0; r < 8; r++) {
        if (r === c) continue;
        const f = A[r][c] / A[c][c];
        for (let k = c; k < 8; k++) A[r][k] -= f * A[c][k];
        B[r] -= f * B[c];
      }
    }
    return B.map((b, i) => b / A[i][i]);
  }
  function warp(src, q, maxSide = 2400) {
    let W = Math.max(dist(q[0], q[1]), dist(q[3], q[2])), H = Math.max(dist(q[0], q[3]), dist(q[1], q[2]));
    const k = Math.min(1, maxSide / Math.max(W, H)); W = Math.max(1, Math.round(W * k)); H = Math.max(1, Math.round(H * k));
    const h = homography([{ x: 0, y: 0 }, { x: W, y: 0 }, { x: W, y: H }, { x: 0, y: H }], q);
    const sw = src.width, sh = src.height, sd = src.getContext('2d').getImageData(0, 0, sw, sh).data;
    const out = document.createElement('canvas'); out.width = W; out.height = H;
    const ox = out.getContext('2d'), img = ox.createImageData(W, H), od = img.data;
    for (let v = 0; v < H; v++) {
      for (let u = 0; u < W; u++) {
        const z = h[6] * u + h[7] * v + 1, x = (h[0] * u + h[1] * v + h[2]) / z, y = (h[3] * u + h[4] * v + h[5]) / z;
        const x0 = Math.max(0, Math.min(sw - 2, x | 0)), y0 = Math.max(0, Math.min(sh - 2, y | 0)), fx = x - x0, fy = y - y0;
        const i = (y0 * sw + x0) * 4, j = (v * W + u) * 4, r = sw * 4;
        for (let ch = 0; ch < 3; ch++) {
          const a = sd[i + ch] + (sd[i + 4 + ch] - sd[i + ch]) * fx, b = sd[i + r + ch] + (sd[i + r + 4 + ch] - sd[i + r + ch]) * fx;
          od[j + ch] = a + (b - a) * fy;
        }
        od[j + 3] = 255;
      }
    }
    ox.putImageData(img, 0, 0);
    return out;
  }

  // ---- looks -------------------------------------------------------------------------------------------
  // Background = very blurred copy; dividing by it removes shadows and makes the paper white.
  function background(c) {
    const s1 = draw(c, c.width >> 3, c.height >> 3), s2 = draw(s1, c.width >> 5, c.height >> 5);
    return draw(s2, c.width, c.height).getContext('2d').getImageData(0, 0, c.width, c.height).data;
  }
  function look(src, mode, bright = 0, contrast = 0) {
    const c = draw(src, src.width, src.height), x = c.getContext('2d');
    const img = x.getImageData(0, 0, c.width, c.height), d = img.data;
    const kc = 1 + contrast / 100, kb = bright * 1.6;
    const adj = (v) => { v = (v - 128) * kc + 128 + kb; return v < 0 ? 0 : v > 255 ? 255 : v; };
    if (mode === 'original') {
      for (let i = 0; i < d.length; i += 4) { d[i] = adj(d[i]); d[i + 1] = adj(d[i + 1]); d[i + 2] = adj(d[i + 2]); }
    } else {
      const bg = background(c);
      for (let i = 0; i < d.length; i += 4) {
        if (mode === 'colour') {
          // per channel: white paper, colours kept, a little extra punch
          let r = d[i] / Math.max(35, bg[i]) * 255, g = d[i + 1] / Math.max(35, bg[i + 1]) * 255, b = d[i + 2] / Math.max(35, bg[i + 2]) * 255;
          const m = (r + g + b) / 3;
          r = m + (r - m) * 1.25; g = m + (g - m) * 1.25; b = m + (b - m) * 1.25;
          d[i] = adj((r - 25) * 1.12); d[i + 1] = adj((g - 25) * 1.12); d[i + 2] = adj((b - 25) * 1.12);
        } else {
          const gray = d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114;
          const back = Math.max(40, bg[i] * 0.299 + bg[i + 1] * 0.587 + bg[i + 2] * 0.114);
          let v = gray / back * 255;
          v = mode === 'bw' ? (v - 75) * 1.55 : (v - 30) * 1.15;
          d[i] = d[i + 1] = d[i + 2] = adj(v);
        }
      }
    }
    x.putImageData(img, 0, 0);
    return c;
  }
  // Long receipt in parts: stack them top to bottom at the same width.
  function stack(parts) {
    if (parts.length === 1) return parts[0];
    const W = Math.min(1800, Math.max(...parts.map((p) => p.width)));
    const scaled = parts.map((p) => draw(p, W, Math.round(p.height * W / p.width)));
    const out = document.createElement('canvas');
    out.width = W; out.height = scaled.reduce((a, p) => a + p.height, 0);
    const x = out.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, out.width, out.height);
    let y = 0; for (const p of scaled) { x.drawImage(p, 0, y); y += p.height; }
    return out;
  }

  // ---- reading the total (OCR, Tesseract.js loaded only when asked) ---------------------------------------
  function loadTesseract() {
    if (root.Tesseract) return Promise.resolve();
    return new Promise((res, rej) => {
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
      s.onload = res; s.onerror = () => rej(new Error('Reading needs an internet connection.'));
      document.head.appendChild(s);
    });
  }
  async function readText(canvas, onProgress) {
    await loadTesseract();
    const worker = await root.Tesseract.createWorker('eng', 1, { logger: (m) => { if (onProgress && m.status === 'recognizing text') onProgress(m.progress); } });
    try { return (await worker.recognize(canvas)).data.text; } finally { worker.terminate(); }
  }
  // Pick the total, VAT and date out of receipt text.
  function parseReceipt(text) {
    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const money = (l) => [...l.replace(/[Oo](?=\d)|(?<=\d)[Oo]/g, '0').matchAll(/£?\s?(\d{1,4})[.,](\d{2})(?!\d|%)/g)].map((m) => +(m[1] + '.' + m[2]));
    let total = null, totalRank = -1;
    const ranks = [[/total\s*(to\s*pay|due|paid)|amount\s*due|balance\s*due|to\s*pay|grand\s*total/i, 3], [/\btotal\b/i, 2], [/\b(sale|card|visa|mastercard|debit|contactless|amount|received|paid)\b/i, 1]];
    for (const l of lines) {
      if (/sub\s*-?\s*total|vat|net\b|change|tip/i.test(l)) continue;
      const a = money(l); if (!a.length) continue;
      for (const [re, r] of ranks) if (re.test(l) && (r > totalRank || (r === totalRank && a[a.length - 1] > total))) { total = a[a.length - 1]; totalRank = r; break; }
    }
    const all = lines.flatMap(money).filter((v) => v > 0 && v < 5000);
    if (total === null && all.length) total = Math.max(...all);
    let vat = null;
    if (total) {
      const cands = lines.filter((l) => /vat/i.test(l)).flatMap(money).filter((v) => v > 0 && v < total * 0.3);
      const twenty = cands.find((v) => Math.abs(v - total / 6) <= 0.02);   // 20% VAT included in the total
      vat = twenty ?? (cands.length ? Math.max(...cands) : null);
    }
    const dm = text.match(/\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b/);
    const date = dm ? `${dm[1].padStart(2, '0')}/${dm[2].padStart(2, '0')}/${dm[3].length === 2 ? '20' + dm[3] : dm[3]}` : null;
    // What kind of expense it looks like.
    const kind = /parking|car ?park|lorry ?park|truck ?stop|overnight|\bsnap\b/i.test(text) ? 'parking'
      : /\b(toll|bridge|crossing|dart ?charge|tunnel)/i.test(text) ? 'tolls'
        : /\b(meal|coffee|tea|sandwich|food|breakfast|lunch|dinner|greggs|mcdonald|costa|subway|burger|kfc|caf[eé]|restaurant|starbucks|drink|pasty|baguette|wrap)\b/i.test(text) ? 'food' : null;
    return { amount: total, vat, date, kind };
  }
  // Read a saved receipt photo (used after Save, in the background).
  async function readFile(file) {
    const bmp = await createImageBitmap(file);
    const k = Math.min(1, 1600 / bmp.width);
    return parseReceipt(await readText(look(draw(bmp, bmp.width * k, bmp.height * k), 'bw')));
  }

  // ---- the scanner screen ----------------------------------------------------------------------------------
  function pickPhoto() {
    return new Promise((res) => {
      const i = document.createElement('input');
      i.type = 'file'; i.accept = 'image/*'; i.setAttribute('capture', 'environment');
      i.onchange = () => res(i.files[0] || null);
      i.click();
    });
  }
  function open(file) {
    return new Promise(async (resolve) => {
      let src;
      try { src = await toCanvas(file); } catch {
        alert('Could not open that photo.' + (/hei[cf]/i.test(file.name + file.type) ? ' iPhone HEIC photos need to be JPG (Settings › Camera › Formats › Most Compatible).' : ''));
        return resolve(null);
      }
      let mode = 'colour';
      try { mode = localStorage.getItem(LS_MODE) || 'colour'; } catch { /* ignore */ }
      if (!MODES[mode]) mode = 'colour';
      const st = { step: 'crop', src, quad: detect(src), parts: [], bright: 0, contrast: 0, info: null, drag: -1, f: 1 };
      const ov = document.createElement('div');
      ov.className = 'scan-ov';
      ov.innerHTML = `<div class="scan-bar scan-top"><b data-x="title">Scan receipt</b><span data-x="hint"></span></div>
        <div class="scan-stage"><canvas></canvas></div>
        <div class="scan-panel">
          <div data-step="crop" class="scan-row">
            <button type="button" class="btn small" data-x="rotl" title="Rotate left">⟲</button>
            <button type="button" class="btn small" data-x="rotr" title="Rotate right">⟳</button>
            <button type="button" class="btn small" data-x="auto">✨ Auto</button>
            <button type="button" class="btn small" data-x="full">⛶ Whole photo</button>
          </div>
          <div data-step="enhance" class="scan-row scan-modes">${Object.entries(MODES).map(([k, v]) => `<button type="button" class="btn small" data-mode="${k}">${v}</button>`).join('')}</div>
          <div data-step="enhance" class="scan-row scan-sliders">
            <label>☀️<input type="range" min="-60" max="60" value="0" data-x="bright" aria-label="Brightness"></label>
            <label>◐<input type="range" min="-50" max="80" value="0" data-x="contrast" aria-label="Contrast"></label>
          </div>
          <div data-step="enhance" class="scan-row">
            <button type="button" class="btn small" data-x="addpart">＋ Add part</button>
            <button type="button" class="btn small" data-x="read">🔍 Read total</button>
            <span class="scan-info" data-x="info"></span>
          </div>
          <div class="scan-row scan-main">
            <button type="button" class="btn" data-x="cancel">Cancel</button>
            <button type="button" class="btn" data-x="back" data-step="enhance">← Crop</button>
            <button type="button" class="btn primary" data-x="next" data-step="crop">Next →</button>
            <button type="button" class="btn primary" data-x="save" data-step="enhance">✓ Save</button>
          </div>
        </div>`;
      document.body.appendChild(ov);
      const $ = (s) => ov.querySelector(s), $$ = (s) => [...ov.querySelectorAll(s)];
      const stage = $('.scan-stage'), cv = $('canvas'), cx = cv.getContext('2d');
      let preview = null, previewSrc = null, timer = null;

      function setStep(s) {
        st.step = s;
        $$('[data-step]').forEach((el) => { el.style.display = el.dataset.step === s ? '' : 'none'; });
        $('[data-x=title]').textContent = s === 'crop' ? (st.parts.length ? `Scan receipt · part ${st.parts.length + 1}` : 'Scan receipt') : 'Enhance';
        $('[data-x=hint]').textContent = s === 'crop' ? 'Drag the corners onto the edges of the receipt' : 'Pick a look, then save';
        $$('[data-mode]').forEach((b) => b.classList.toggle('primary', b.dataset.mode === mode));
        layout();
      }
      function layout() {
        const img = st.step === 'crop' ? st.src : preview;
        if (!img) return;
        const W = stage.clientWidth - 16, H = stage.clientHeight - 16;
        st.f = Math.min(W / img.width, H / img.height, 2);
        cv.width = Math.round(img.width * st.f); cv.height = Math.round(img.height * st.f);
        paint();
      }
      function paint() {
        if (st.step === 'enhance') { cx.drawImage(preview, 0, 0, cv.width, cv.height); return; }
        const f = st.f, q = st.quad;
        cx.drawImage(st.src, 0, 0, cv.width, cv.height);
        cx.save();
        cx.fillStyle = 'rgba(0,0,0,.5)';
        cx.beginPath(); cx.rect(0, 0, cv.width, cv.height);
        q.forEach((p, i) => (i ? cx.lineTo(p.x * f, p.y * f) : cx.moveTo(p.x * f, p.y * f))); cx.closePath();
        cx.fill('evenodd');
        cx.strokeStyle = '#4f8bff'; cx.lineWidth = 2.5;
        cx.beginPath(); q.forEach((p, i) => (i ? cx.lineTo(p.x * f, p.y * f) : cx.moveTo(p.x * f, p.y * f))); cx.closePath(); cx.stroke();
        q.forEach((p, i) => {
          cx.beginPath(); cx.arc(p.x * f, p.y * f, i === st.drag ? 16 : 13, 0, 7);
          cx.fillStyle = 'rgba(79,139,255,.35)'; cx.fill(); cx.lineWidth = 3; cx.stroke();
        });
        if (st.drag >= 0) loupe(q[st.drag]);
        cx.restore();
      }
      // Magnifier: what's under your finger, zoomed, in the opposite top corner.
      function loupe(p) {
        const R = Math.min(70, cv.width / 4), zoom = 3, f = st.f;
        const lx = p.x * f < cv.width / 2 ? cv.width - R - 10 : R + 10, ly = R + 10;
        cx.save();
        cx.beginPath(); cx.arc(lx, ly, R, 0, 7); cx.closePath();
        cx.fillStyle = '#000'; cx.fill(); cx.clip();
        const s = R / zoom;   // half-size of the source area, in display px
        cx.drawImage(st.src, (p.x * f - s) / f, (p.y * f - s) / f, (2 * s) / f, (2 * s) / f, lx - R, ly - R, 2 * R, 2 * R);
        cx.strokeStyle = '#ff5a5a'; cx.lineWidth = 1.5;
        cx.beginPath(); cx.moveTo(lx - R, ly); cx.lineTo(lx + R, ly); cx.moveTo(lx, ly - R); cx.lineTo(lx, ly + R); cx.stroke();
        cx.restore();
        cx.beginPath(); cx.arc(lx, ly, R, 0, 7); cx.strokeStyle = '#fff'; cx.lineWidth = 3; cx.stroke();
      }
      const at = (e) => { const r = cv.getBoundingClientRect(); return { x: (e.clientX - r.left) * (cv.width / r.width) / st.f, y: (e.clientY - r.top) * (cv.height / r.height) / st.f }; };
      cv.onpointerdown = (e) => {
        if (st.step !== 'crop') return;
        const p = at(e); let bd = Infinity;
        st.quad.forEach((q, i) => { const dd = dist(q, p) * st.f; if (dd < bd) { bd = dd; st.drag = i; } });
        if (bd > 60) st.drag = -1; else { cv.setPointerCapture(e.pointerId); paint(); }
      };
      cv.onpointermove = (e) => {
        if (st.drag < 0) return;
        const p = at(e);
        st.quad[st.drag] = { x: Math.max(0, Math.min(st.src.width, p.x)), y: Math.max(0, Math.min(st.src.height, p.y)) };
        paint();
      };
      cv.onpointerup = cv.onpointercancel = () => { st.drag = -1; paint(); };

      // Preview works on a smaller copy so the sliders feel instant; Save redoes it at full size.
      function current() { return stack([...st.parts, warp(st.src, st.quad)]); }
      function refresh() {
        const k = Math.min(1, 1000 / Math.max(previewSrc.width, previewSrc.height));
        preview = look(draw(previewSrc, previewSrc.width * k, previewSrc.height * k), mode, st.bright, st.contrast);
        layout();
      }
      function toEnhance() {
        previewSrc = current();
        setStep('enhance');
        refresh();
      }
      const done = (v) => { window.removeEventListener('resize', layout); ov.remove(); resolve(v); };
      $('[data-x=cancel]').onclick = () => done(null);
      $('[data-x=rotl]').onclick = () => { st.src = rotate(st.src, -1); st.quad = detect(st.src); layout(); };
      $('[data-x=rotr]').onclick = () => { st.src = rotate(st.src, 1); st.quad = detect(st.src); layout(); };
      $('[data-x=auto]').onclick = () => { st.quad = detect(st.src); paint(); };
      $('[data-x=full]').onclick = () => { st.quad = fullFrame(st.src); paint(); };
      $('[data-x=next]').onclick = async () => { $('[data-x=next]').textContent = 'Working…'; await new Promise((r) => setTimeout(r, 20)); toEnhance(); $('[data-x=next]').textContent = 'Next →'; };
      $('[data-x=back]').onclick = () => setStep('crop');
      $$('[data-mode]').forEach((b) => b.onclick = () => {
        mode = b.dataset.mode;
        try { localStorage.setItem(LS_MODE, mode); } catch { /* ignore */ }
        $$('[data-mode]').forEach((x) => x.classList.toggle('primary', x === b));
        refresh();
      });
      $$('input[type=range]').forEach((r) => r.oninput = () => {
        st[r.dataset.x] = +r.value;
        clearTimeout(timer); timer = setTimeout(refresh, 40);
      });
      $('[data-x=addpart]').onclick = async () => {
        const f = await pickPhoto();
        if (!f) return;
        try { const next = await toCanvas(f); st.parts.push(warp(st.src, st.quad)); st.src = next; st.quad = detect(next); setStep('crop'); }
        catch { alert('Could not open that photo.'); }
      };
      $('[data-x=read]').onclick = async () => {
        const info = $('[data-x=info]'), btn = $('[data-x=read]');
        btn.disabled = true; info.textContent = 'Loading reader…';
        try {
          const k = Math.min(1, 1600 / previewSrc.width);
          const text = await readText(look(draw(previewSrc, previewSrc.width * k, previewSrc.height * k), 'bw'), (p) => { info.textContent = `Reading… ${Math.round(p * 100)}%`; });
          st.info = parseReceipt(text);
          info.textContent = st.info.amount ? `Total £${st.info.amount.toFixed(2)}${st.info.vat ? ` · VAT £${st.info.vat.toFixed(2)}` : ''}${st.info.date ? ` · ${st.info.date}` : ''}` : "Couldn't find a total. Type it in.";
        } catch (e) { info.textContent = e.message || 'Reading failed.'; }
        btn.disabled = false;
      };
      $('[data-x=save]').onclick = async () => {
        const btn = $('[data-x=save]'); btn.disabled = true; btn.textContent = 'Saving…';
        await new Promise((r) => setTimeout(r, 20));
        const out = look(previewSrc, mode, st.bright, st.contrast);
        out.toBlob((b) => {
          const f = new File([b], 'receipt-scan.jpg', { type: 'image/jpeg' });
          if (st.info) f.scanInfo = st.info;
          done(f);
        }, 'image/jpeg', 0.88);
      };
      window.addEventListener('resize', layout);
      setTimeout(() => setStep('crop'), 30);
    });
  }

  root.Scanner = { open, detect, warp, look, stack, parseReceipt, readFile };
})(typeof self !== 'undefined' ? self : globalThis);
