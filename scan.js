/* Receipt scanner: finds the paper in a photo, lets you drag the corners, straightens it
 * and cleans it up like a scanner would. Scanner.open(file) resolves to a JPEG File, or null. */
(function (root) {
  'use strict';

  async function toCanvas(file, max = 2200) {
    const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
    const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    return c;
  }
  function rotate(c) {
    const o = document.createElement('canvas');
    o.width = c.height; o.height = c.width;
    const x = o.getContext('2d');
    x.translate(o.width, 0); x.rotate(Math.PI / 2); x.drawImage(c, 0, 0);
    return o;
  }

  // The receipt is the biggest bright blob; its corners are the blob's extreme points.
  function detect(c) {
    const k = Math.min(1, 320 / Math.max(c.width, c.height));
    const w = Math.max(1, Math.round(c.width * k)), h = Math.max(1, Math.round(c.height * k));
    const s = document.createElement('canvas'); s.width = w; s.height = h;
    const sx = s.getContext('2d'); sx.drawImage(c, 0, 0, w, h);
    const d = sx.getImageData(0, 0, w, h).data, n = w * h, g = new Uint8Array(n), hist = new Array(256).fill(0);
    for (let i = 0; i < n; i++) { const v = (d[i * 4] * 0.299 + d[i * 4 + 1] * 0.587 + d[i * 4 + 2] * 0.114) | 0; g[i] = v; hist[v]++; }
    let sum = 0; for (let i = 0; i < 256; i++) sum += i * hist[i];
    let sumB = 0, wB = 0, best = 0, t = 128;   // Otsu threshold: paper vs background
    for (let i = 0; i < 256; i++) {
      wB += hist[i]; if (!wB) continue;
      const wF = n - wB; if (!wF) break;
      sumB += i * hist[i];
      const v = wB * wF * (sumB / wB - (sum - sumB) / wF) ** 2;
      if (v > best) { best = v; t = i; }
    }
    const lab = new Uint8Array(n), stack = new Int32Array(n);
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
    if (!top || top.size < n * 0.06 || top.size > n * 0.97) {   // nothing obvious: start with a frame inside the photo
      const mx = c.width * 0.06, my = c.height * 0.06;
      return [{ x: mx, y: my }, { x: c.width - mx, y: my }, { x: c.width - mx, y: c.height - my }, { x: mx, y: c.height - my }];
    }
    return [top.tl, top.tr, top.br, top.bl].map(([x, y]) => ({ x: (x + 0.5) / k, y: (y + 0.5) / k }));
  }

  // Homography taking output-rectangle points to the photo's quad (solved as an 8x8 system).
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
  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  function warp(src, q, maxSide = 1800) {
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
        const i = (y0 * sw + x0) * 4, j = (v * W + u) * 4;
        for (let ch = 0; ch < 3; ch++) {
          const a = sd[i + ch] + (sd[i + 4 + ch] - sd[i + ch]) * fx, b = sd[i + sw * 4 + ch] + (sd[i + sw * 4 + 4 + ch] - sd[i + sw * 4 + ch]) * fx;
          od[j + ch] = a + (b - a) * fy;
        }
        od[j + 3] = 255;
      }
    }
    ox.putImageData(img, 0, 0);
    return out;
  }
  // Scanner look: divide by the blurred background (removes shadows), then boost contrast.
  function clean(c) {
    const w = c.width, h = c.height, x = c.getContext('2d'), img = x.getImageData(0, 0, w, h), d = img.data;
    const s1 = document.createElement('canvas'); s1.width = Math.max(1, w >> 3); s1.height = Math.max(1, h >> 3);
    s1.getContext('2d').drawImage(c, 0, 0, s1.width, s1.height);
    const s2 = document.createElement('canvas'); s2.width = Math.max(1, w >> 5); s2.height = Math.max(1, h >> 5);
    s2.getContext('2d').drawImage(s1, 0, 0, s2.width, s2.height);
    const b = document.createElement('canvas'); b.width = w; b.height = h;
    const bx = b.getContext('2d'); bx.imageSmoothingEnabled = true; bx.imageSmoothingQuality = 'high'; bx.drawImage(s2, 0, 0, w, h);
    const bg = bx.getImageData(0, 0, w, h).data;
    for (let i = 0; i < d.length; i += 4) {
      const gray = d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114;
      const back = Math.max(40, bg[i] * 0.299 + bg[i + 1] * 0.587 + bg[i + 2] * 0.114);
      let v = (gray / back) * 255;
      v = (v - 70) * 1.45;
      v = v < 0 ? 0 : v > 255 ? 255 : v;
      d[i] = d[i + 1] = d[i + 2] = v;
    }
    x.putImageData(img, 0, 0);
    return c;
  }

  function open(file) {
    return new Promise(async (resolve) => {
      let src;
      try { src = await toCanvas(file); } catch (e) {
        alert('Could not open that photo.' + (/hei[cf]/i.test(file.name + file.type) ? ' iPhone HEIC photos need to be JPG (Settings › Camera › Formats › Most Compatible).' : ''));
        return resolve(null);
      }
      let quad = detect(src);
      const ov = document.createElement('div');
      ov.className = 'scan-ov';
      ov.innerHTML = `<div class="scan-bar"><b>Scan receipt</b><span>Drag the corners onto the edges of the receipt</span></div>
        <div class="scan-stage"><canvas></canvas></div>
        <div class="scan-bar">
          <button type="button" class="btn" data-x="cancel">Cancel</button>
          <button type="button" class="btn" data-x="rotate">⟳ Rotate</button>
          <select data-x="mode" aria-label="Look"><option value="clean">Clean (black &amp; white)</option><option value="colour">Colour</option></select>
          <button type="button" class="btn primary" data-x="use">Use scan</button></div>`;
      document.body.appendChild(ov);
      const stage = ov.querySelector('.scan-stage'), cv = ov.querySelector('canvas'), cx = cv.getContext('2d');
      let f = 1, drag = -1;
      function layout() {
        const W = stage.clientWidth - 16, H = stage.clientHeight - 16;
        f = Math.min(W / src.width, H / src.height);
        cv.width = Math.round(src.width * f); cv.height = Math.round(src.height * f);
        draw();
      }
      function draw() {
        cx.drawImage(src, 0, 0, cv.width, cv.height);
        cx.save();
        cx.fillStyle = 'rgba(0,0,0,.45)';
        cx.beginPath(); cx.rect(0, 0, cv.width, cv.height);
        quad.forEach((p, i) => (i ? cx.lineTo(p.x * f, p.y * f) : cx.moveTo(p.x * f, p.y * f))); cx.closePath();
        cx.fill('evenodd');
        cx.strokeStyle = '#4f8bff'; cx.lineWidth = 2.5;
        cx.beginPath(); quad.forEach((p, i) => (i ? cx.lineTo(p.x * f, p.y * f) : cx.moveTo(p.x * f, p.y * f))); cx.closePath(); cx.stroke();
        for (const p of quad) { cx.beginPath(); cx.arc(p.x * f, p.y * f, 13, 0, 7); cx.fillStyle = 'rgba(79,139,255,.35)'; cx.fill(); cx.lineWidth = 3; cx.stroke(); }
        cx.restore();
      }
      const at = (e) => { const r = cv.getBoundingClientRect(); return { x: (e.clientX - r.left) * (cv.width / r.width) / f, y: (e.clientY - r.top) * (cv.height / r.height) / f }; };
      cv.onpointerdown = (e) => {
        const p = at(e); let bd = Infinity;
        quad.forEach((q, i) => { const dd = dist(q, p) * f; if (dd < bd) { bd = dd; drag = i; } });
        if (bd > 60) drag = -1; else cv.setPointerCapture(e.pointerId);
      };
      cv.onpointermove = (e) => {
        if (drag < 0) return;
        const p = at(e);
        quad[drag] = { x: Math.max(0, Math.min(src.width, p.x)), y: Math.max(0, Math.min(src.height, p.y)) };
        draw();
      };
      cv.onpointerup = cv.onpointercancel = () => { drag = -1; };
      const done = (v) => { window.removeEventListener('resize', layout); ov.remove(); resolve(v); };
      ov.querySelector('[data-x=cancel]').onclick = () => done(null);
      ov.querySelector('[data-x=rotate]').onclick = () => { src = rotate(src); quad = detect(src); layout(); };
      ov.querySelector('[data-x=use]').onclick = async () => {
        const btn = ov.querySelector('[data-x=use]'); btn.disabled = true; btn.textContent = 'Working…';
        await new Promise((r) => setTimeout(r, 30));
        let out = warp(src, quad);
        if (ov.querySelector('[data-x=mode]').value === 'clean') out = clean(out);
        out.toBlob((b) => done(new File([b], 'receipt-scan.jpg', { type: 'image/jpeg' })), 'image/jpeg', 0.85);
      };
      window.addEventListener('resize', layout);
      requestAnimationFrame(layout);
    });
  }

  root.Scanner = { open, detect, warp, clean };
})(typeof self !== 'undefined' ? self : globalThis);
