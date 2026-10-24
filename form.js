/* Draws the Conway Bailey weekly timesheet (page 1) and subsistence/expenses claim (page 2)
 * as clean vector pages, fills them, and appends receipt attachments.
 * Layout numbers are in "scan pixels" measured from the original paper form and mapped to A4. */
(function (root) {
  'use strict';
  const PDFLib = root.PDFLib || (typeof require !== 'undefined' ? require('pdf-lib') : null);
  const { PDFDocument, StandardFonts, rgb, LineCapStyle } = PDFLib;

  // pdf-lib's widthOfTextAtSize subtracts kerning but drawText doesn't kern, so measure glyph by glyph.
  const tw = (font, t, size) => { let w = 0; for (const ch of String(t)) w += font.widthOfTextAtSize(ch, size); return w; };
  const INK = rgb(0, 0, 0);
  const FILL = rgb(0.06, 0.17, 0.5);        // filled-in values: dark blue, like a biro
  const A4L = [841.89, 595.28], A4P = [595.28, 841.89];

  // ---- drawing context --------------------------------------------------
  function ctx(page, fonts, map) {
    const H = page.getHeight();
    const X = (px) => map.ox + (px - map.cx) * map.s;
    const Y = (py) => H - (map.oy + (py - map.cy) * map.s);
    const S = (px) => px * map.s;
    const c = { page, fonts, X, Y, S };

    c.width = (t, font, size) => tw(font, t, size);
    // Font size so that `t` spans `spanPx` scan pixels.
    c.sizeFor = (t, font, spanPx) => S(spanPx) / tw(font, t, 1);

    c.text = (t, px, py, size, o = {}) => {
      if (t === undefined || t === null) return;
      t = String(t).replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, '-')
        .replace(/[^\x20-\x7E\xA0-\xFF£]/g, '');
      if (!t) return;
      const font = o.font || fonts.reg;
      let sz = size;
      if (o.maxPx) { const w = tw(font, t, sz); if (w > S(o.maxPx)) sz = sz * S(o.maxPx) / w; }
      if (o.minSize && sz < o.minSize) {           // still too long: truncate
        sz = o.minSize;
        while (t.length > 1 && tw(font, t, sz) > S(o.maxPx)) t = t.slice(0, -1);
      }
      const w = tw(font, t, sz);
      let x = X(px);
      if (o.align === 'center') x -= w / 2; else if (o.align === 'right') x -= w;
      // Word by word, so spacing follows our metrics and not the viewer's substitute font.
      let wx = x;
      for (const part of t.split(/( +)/)) {
        if (part && part[0] !== ' ') page.drawText(part, { x: wx, y: Y(py), size: sz, font, color: o.color || INK });
        wx += tw(font, part, sz);
      }
      if (o.underline) page.drawLine({ start: { x, y: Y(py) - sz * 0.12 }, end: { x: x + w, y: Y(py) - sz * 0.12 }, thickness: sz * 0.06, color: o.color || INK });
      return w;
    };
    // Justified line: stretch word gaps so the line spans x1..x2.
    c.justify = (t, x1, x2, py, size, font) => {
      const words = t.split(/\s+/).filter(Boolean);
      const total = words.reduce((a, w) => a + tw(font, w, size), 0);
      const gap = (S(x2 - x1) - total) / (words.length - 1);
      let x = X(x1);
      for (const w of words) { page.drawText(w, { x, y: Y(py), size, font, color: INK }); x += tw(font, w, size) + gap; }
    };
    c.line = (x1, y1, x2, y2, th = 1.4) => page.drawLine({ start: { x: X(x1), y: Y(y1) }, end: { x: X(x2), y: Y(y2) }, thickness: S(th), color: INK });
    c.dots = (x1, x2, py) => page.drawLine({ start: { x: X(x1), y: Y(py) }, end: { x: X(x2), y: Y(py) }, thickness: 0.7, color: INK, dashArray: [0.01, 1.9], lineCap: LineCapStyle.Round });
    c.rect = (x1, y1, x2, y2, th) => { c.line(x1, y1, x2, y1, th); c.line(x2, y1, x2, y2, th); c.line(x2, y2, x1, y2, th); c.line(x1, y2, x1, y1, th); };
    c.tick = (cx, cy, h, color = FILL) => {
      const k = S(h);
      const p = [[X(cx) - k * 0.45, Y(cy) + k * 0.05], [X(cx) - k * 0.1, Y(cy) - k * 0.4], [X(cx) + k * 0.5, Y(cy) + k * 0.55]];
      page.drawLine({ start: { x: p[0][0], y: p[0][1] }, end: { x: p[1][0], y: p[1][1] }, thickness: 1.3, color, lineCap: LineCapStyle.Round });
      page.drawLine({ start: { x: p[1][0], y: p[1][1] }, end: { x: p[2][0], y: p[2][1] }, thickness: 1.3, color, lineCap: LineCapStyle.Round });
    };
    c.circle = (x1, x2, py, color = FILL) => {   // ellipse around a word whose baseline is py
      const cx = (X(x1) + X(x2)) / 2, w = (X(x2) - X(x1)) / 2 + S(5), h = S(13);
      page.drawEllipse({ x: cx, y: Y(py) + S(6), xScale: w, yScale: h, borderColor: color, borderWidth: 1.1 });
    };
    // Wrapped text inside a box; shrinks the font until it fits.
    c.box = (t, x1, y1, x2, y2, size, o = {}) => {
      if (!t) return;
      const font = o.font || fonts.reg, maxW = S(x2 - x1), maxH = S(y2 - y1);
      const paras = String(t).replace(/[^\x20-\x7E\xA0-\xFF\n£]/g, '').split('\n');
      let sz = size, lines;
      for (; sz >= 5; sz -= 0.25) {
        lines = [];
        for (const para of paras) {
          let cur = '';
          for (const w of para.split(/\s+/).filter(Boolean)) {
            const tryLine = cur ? cur + ' ' + w : w;
            if (tw(font, tryLine, sz) <= maxW || !cur) cur = tryLine; else { lines.push(cur); cur = w; }
          }
          if (cur) lines.push(cur);
        }
        if (lines.length * sz * 1.18 <= maxH && lines.every((l) => tw(font, l, sz) <= maxW)) break;
      }
      const lh = sz * 1.18, top = Y(y1) - sz * 0.95;
      lines.forEach((l, i) => page.drawText(l, { x: X(x1), y: top - i * lh, size: sz, font, color: o.color || FILL }));
    };
    c.image = async (doc, dataUrl, x1, y1, x2, y2) => {
      if (!dataUrl) return;
      const bytes = dataUrlBytes(dataUrl);
      const img = dataUrl.startsWith('data:image/png') ? await doc.embedPng(bytes) : await doc.embedJpg(bytes);
      const bw = S(x2 - x1), bh = S(y2 - y1), k = Math.min(bw / img.width, bh / img.height);
      const w = img.width * k, h = img.height * k;
      page.drawImage(img, { x: X(x1) + (bw - w) / 2, y: Y(y2) + (bh - h) / 2, width: w, height: h });
    };
    return c;
  }

  function dataUrlBytes(u) {
    const b64 = u.slice(u.indexOf(',') + 1);
    if (typeof atob === 'function') { const s = atob(b64), a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
    return Uint8Array.from(Buffer.from(b64, 'base64'));
  }

  // ---- page 1: weekly timesheet -----------------------------------------
  const P1 = {
    cols: [105, 213, 457, 865, 1210, 1298, 1387],
    top: 110, head: 148, rowH: 100.57,
    days: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
  };

  async function page1(doc, fonts, d) {
    const page = doc.addPage(A4L);
    const c = ctx(page, fonts, { s: 0.57, cx: 746, cy: 526, ox: A4L[0] / 2, oy: A4L[1] / 2 });
    const B = fonts.bold, R = fonts.reg, { cols, top, head, rowH } = P1;
    const bottom = head + rowH * 7;

    // header
    const hs = c.sizeFor('Weekly Timesheet', B, 146);
    c.text('Name:', 104, 66, hs, { font: B });
    c.line(157, 72, 600, 72, 1.1);
    c.text('Weekly Timesheet', 676, 70, hs, { font: B });
    c.text('Week Commening: Sunday', 893, 72, hs, { font: B });
    c.line(1105, 78, 1390, 78, 1.1);

    // table grid
    c.rect(cols[0], top, cols[6], bottom, 2.2);
    c.line(cols[0], head, cols[6], head, 1.8);
    for (let i = 1; i < 6; i++) c.line(cols[i], top, cols[i], bottom, i >= 4 ? 1.6 : 1.8);
    for (let r = 1; r < 7; r++) c.line(cols[0], head + r * rowH, cols[6], head + r * rowH, 1.6);

    await c.image(doc, root.CBT_LOGO, 117, 114, 200, 143);
    const th = c.sizeFor('Start and Finish Times', B, 175);
    c.text('Start and Finish Times', (cols[1] + cols[2]) / 2, 140, th, { font: B, align: 'center' });
    c.text('Start and Finish Place', (cols[2] + cols[3]) / 2, 141, th, { font: B, align: 'center' });
    c.text('Drops', (cols[3] + cols[4]) / 2, 144, th, { font: B, align: 'center' });
    const sm = c.sizeFor('Night Out (UK', B, 80);
    c.text('Night Out (UK', (cols[4] + cols[5]) / 2, 127, sm, { font: B, align: 'center' });
    c.text('or EU)', (cols[4] + cols[5]) / 2, 145, sm, { font: B, align: 'center' });
    c.text('No of Driving', (cols[5] + cols[6]) / 2, 127, sm, { font: B, align: 'center' });
    c.text('Hours used', (cols[5] + cols[6]) / 2, 145, sm, { font: B, align: 'center' });

    const ds = c.sizeFor('Wednesday', B, 92), ls = c.sizeFor('Finish Time:', R, 92);
    P1.days.forEach((day, i) => {
      const T = head + i * rowH, y1 = T + 42, y2 = T + 92;
      c.text(day, (cols[0] + cols[1]) / 2, y1, ds, { font: B, align: 'center' });
      c.text('Start Time:', 220, y1, ls); c.line(310, y1 + 4, 427, y1 + 4, 1); c.text('hrs', 428, y1, ls);
      c.text('Finish Time:', 220, y2, ls); c.line(316, y2 + 4, 427, y2 + 4, 1); c.text('hrs', 428, y2, ls);
      c.text('Start Place:', 461, y1, ls); c.line(549, y1 + 5, 862, y1 + 5, 1);
      c.text(i === 3 ? 'finish Place:' : 'Finish Place:', 461, y2, ls); c.line(558, y2 + 5, 862, y2 + 5, 1);

      const v = (d.days && d.days[i]) || {};
      const fs = 11.5;
      c.text(v.startTime, 369, y1 - 2, fs, { color: FILL, align: 'center', maxPx: 112 });
      c.text(v.finishTime, 372, y2 - 2, fs, { color: FILL, align: 'center', maxPx: 108 });
      c.text(v.startPlace, 556, y1 - 2, 10.5, { color: FILL, maxPx: 302, minSize: 6.5 });
      c.text(v.finishPlace, 565, y2 - 2, 10.5, { color: FILL, maxPx: 294, minSize: 6.5 });
      c.box(v.drops, cols[3] + 6, T + 6, cols[4] - 5, T + rowH - 4, 9.5);
      if (v.nightOut) {
        c.tick((cols[4] + cols[5]) / 2 - 14, T + 50, 26);
        c.text(v.nightOut, (cols[4] + cols[5]) / 2 + 14, T + 60, 8, { color: FILL, align: 'center' });
      }
      c.text(v.driving, (cols[5] + cols[6]) / 2, T + 60, 10.5, { color: FILL, align: 'center', maxPx: 84 });
    });

    // footer
    const decl = 'Declaration : I declare that I have not had any accidents/caused and damage/failed to return paperwork or failed to make myself available for work';
    const fsz = c.sizeFor(decl, B, 1176);
    c.text(decl, 107, 873, fsz, { font: B });
    c.text('YES/NO', 1313, 876, fsz, { font: B });
    const by = 920;
    c.text('have worked the following:', 109, by - 2, fsz, { font: B });
    c.text('Total Weekdays', 349, by, fsz, { font: B }); c.line(481, by + 2, 529, by + 2, 1);
    c.text('Total Weekend Days', 559, by + 1, fsz, { font: B }); c.line(727, by + 3, 786, by + 3, 1);
    c.text('24hr Away from home', 815, by + 2, fsz, { font: B });
    const yw = c.width('YES/', B, fsz) / 0.57, yesW = c.width('YES', B, fsz) / 0.57, noW = c.width('NO', B, fsz) / 0.57;
    c.text('YES/NO', 996, by + 2, fsz, { font: B });
    c.text('Signed:', 1110, by + 4, fsz, { font: B }); c.line(1170, by + 6, 1388, by + 6, 1);
    c.text('Conway Bailey Transport Ltd 2015', 746, 1004, c.sizeFor('Conway Bailey Transport Ltd 2015', R, 267), { align: 'center' });

    // filled footer values
    c.text(d.totalWeekdays, 505, by - 3, 12, { color: FILL, align: 'center' });
    c.text(d.totalWeekendDays, 756, by - 2, 12, { color: FILL, align: 'center' });
    if (d.away24 === 'YES') c.circle(996, 996 + yesW, by + 2); else if (d.away24 === 'NO') c.circle(996 + yw, 996 + yw + noW, by + 2);
    if (d.declaration === 'YES') c.circle(1313, 1313 + yesW, 876); else if (d.declaration === 'NO') c.circle(1313 + yw, 1313 + yw + noW, 876);
    await c.image(doc, d.signature, 1175, by - 36, 1385, by + 6);
    c.text(d.name, 165, 63, 12, { color: FILL, maxPx: 432 });
    c.text(d.weekCommencing, 1110, 70, 12, { color: FILL, maxPx: 278 });
  }

  // ---- page 2: subsistence claim + expenses -------------------------------
  const P2 = {
    cols: [124.3, 191.7, 304.8, 407.9, 515.7, 620.2, 729.5, 831.1, 936.6],
    subs: [356.1, 461.5, 568.4, 674.8, 780.8, 884.3],
    rows: [933.7, 997.8, 1033.4, 1070, 1104.2, 1138.9, 1172.6, 1206.8, 1241.5, 1277.1],
    split: 978.3,
  };
  const P2_DAYS = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

  async function page2(doc, fonts, d) {
    const page = doc.addPage(A4P);
    const c = ctx(page, fonts, { s: 0.551, cx: 530.5, cy: 764, ox: A4P[0] / 2, oy: A4P[1] / 2 });
    const R = fonts.times, B = fonts.timesBold;

    const body = [
      ['I wish to apply for the payment of tax free subsistence allowance at the rate agreed with my employer and in',
        'accordance with the agreement reached between the Inland Revenue, the Employers Associations and Trade',
        'Unions representing the Road Transport Industry.'],
      ['I certify that this claim arises because on the under mentioned dates my duties involved my living away from',
        'my normal permanent address, and I stayed at the places given below.'],
      ['I declare that I have continuing financial commitments in relation to my permanent address shown above, and',
        'this claim represents an allowance in respect of the additional necessary expenses which I have incurred as a',
        'direct result of my employment.'],
      ['I declare that the above particulars are true and understand that they may be checked by the Inland Revenue.'],
    ];
    const bs = c.sizeFor(body[0][0], R, 811) * 0.995;
    const hsz = c.sizeFor('EMPLOYEES NAME (BLOCK LETTERS)', R, 296);

    c.text('TO: CONWAY BAILEY TRANSPORT LTD', 126, 181, hsz, { font: R });
    c.text('EMPLOYEES NAME (BLOCK LETTERS)', 126, 201, hsz, { font: R });
    c.dots(482, 836, 198);
    c.text('PERMANENT ADDRESS', 126, 239, hsz, { font: R });
    c.dots(482, 836, 236);
    c.dots(482, 836, 276);
    c.text('NATIONAL INSURANCE NUMBER', 126, 316, hsz, { font: R });
    c.dots(388, 576, 316);
    c.text('VEHICLE NO', 594, 314, hsz, { font: R });
    c.dots(691, 842, 314);

    const baselines = [[352, 374, 396], [437, 459], [499, 522, 544], [585]];
    body.forEach((p, i) => p.forEach((l, j) => {
      if (j < p.length - 1) c.justify(l, 126, 937, baselines[i][j], bs, R); else c.text(l, 126, baselines[i][j], bs, { font: R });
    }));
    c.text('Signed', 124, 630, bs, { font: R }); c.dots(183, 476, 630);
    c.text('Date', 484, 630, bs, { font: R }); c.dots(524, 741, 630);

    c.text('EMPLOYERS CERTIFICATE', 532, 672, c.sizeFor('EMPLOYERS CERTIFICATE', B, 211), { font: B, align: 'center' });
    const es = bs * 1.07;
    const e1a = 'I certify that the permanent address given by Mr.', e1b = 'is his normal place of';
    c.text(e1a, 124, 715, es, { font: R });
    c.dots(c.width(e1a, R, es) / 0.551 + 130, 745, 715);
    c.text(e1b, 937, 715, es, { font: R, align: 'right' });
    c.justify('residence and that to the best of my knowledge this claim for tax free subsistence allowance satisfies', 124, 937, 738, es, R);
    c.text('the requirement of the Inland Revenue.', 124, 761, es, { font: R });
    c.text('Signed', 124, 806, es, { font: R }); c.dots(186, 437, 806);
    c.text('(Transport Manager)', 440, 806, es, { font: R });
    c.text('Date', 662, 806, es, { font: R }); c.dots(705, 905, 806);

    const ws = c.sizeFor('EMPLOYEE/EMPLOYER OR BOTH LIABLE TO PROSECUTION BY THE INLAND REVENUE.', R, 690);
    c.text('WARNING:', 124, 846, ws, { font: R, underline: true });
    c.justify('A FALSE DECLARATION ON THIS CERTIFICATE MAY RENDER THE', 124 + c.width('WARNING:', R, ws) / 0.551 + 28, 937, 846, ws, R);
    c.text('EMPLOYEE/EMPLOYER OR BOTH LIABLE TO PROSECUTION BY THE INLAND REVENUE.', 124, 866, ws, { font: R });

    c.text('EXPENSES', 472, 906, c.sizeFor('EXPENSES', B, 94), { font: B, align: 'center' });
    c.text('W/E DATE', 605, 906, ws, { font: R }); c.dots(688, 886, 906);

    // expenses grid
    const { cols, subs, rows, split } = P2;
    c.rect(cols[0], rows[0], cols[8], rows[9], 1.4);
    for (let i = 1; i < 8; i++) c.line(cols[i], rows[0], cols[i], rows[9], 1.3);
    for (let r = 1; r < 9; r++) c.line(cols[0], rows[r], cols[8], rows[r], 1.3);
    c.line(cols[2], split, cols[3], split, 1.2);
    c.line(subs[0], split, subs[0], rows[9], 1.2);
    for (let i = 1; i < subs.length; i++) c.line(subs[i], rows[1], subs[i], rows[9], 1.2);
    const ts = c.sizeFor('EXPENSES', R, 94) * 0.98, mid = (a, b) => (a + b) / 2;
    c.text('PLACE', mid(cols[1], cols[2]), 972, ts, { font: R, align: 'center' });
    c.text('NIGHTS', mid(cols[2], cols[3]), 951, ts, { font: R, align: 'center' });
    c.text('OUT', mid(cols[2], cols[3]), 972, ts, { font: R, align: 'center' });
    c.text('UK', mid(cols[2], subs[0]), 993, ts * 0.8, { font: R, align: 'center' });
    c.text('EU', mid(subs[0], cols[3]), 993, ts * 0.8, { font: R, align: 'center' });
    c.text('PARKING', mid(cols[3], cols[4]), 972, ts, { font: R, align: 'center' });
    c.text('BRIDGE/', mid(cols[4], cols[5]), 961, ts, { font: R, align: 'center' });
    c.text('TOLLS', mid(cols[4], cols[5]), 982, ts, { font: R, align: 'center' });
    c.text('MARKET', mid(cols[5], cols[6]), 961, ts, { font: R, align: 'center' });
    c.text('EXPENSES', mid(cols[5], cols[6]), 982, ts, { font: R, align: 'center' });
    c.text('VAT', mid(cols[6], cols[7]), 971, ts, { font: R, align: 'center' });
    c.text('TOTAL', mid(cols[7], cols[8]), 971, ts, { font: R, align: 'center' });
    P2_DAYS.forEach((t, i) => c.text(t, mid(cols[0], cols[1]), rows[i + 1] + 24, ts, { font: R, align: 'center' }));
    c.text('TOTALS', mid(cols[1], cols[2]), rows[8] + 24, ts, { font: R, align: 'center' });

    c.text('EXPENSES', 181, 1313, ws * 1.05, { font: R });
    c.text('£', 302, 1312, ws * 1.05, { font: R });
    c.dots(485, 770, 1312);
    c.text('AUTHORISED BY', 771, 1312, ws * 1.05, { font: R });
    const fb = c.sizeFor('ATTACH RECEIPTS WHERE APPLICABLE FOR PAYMENTS TO BE MADE.', B, 595);
    const l1 = 'ALL PARKING MUST BE AUTHORISED BY THE OFFICE PRIOR TO UNDERTAKING.  YOU MUST';
    const l1w = c.text(l1, 530, 1353, fb, { font: B, align: 'center' }), l1x = c.X(530) - l1w / 2;
    for (const at of [l1.indexOf('MUST'), l1.lastIndexOf('MUST')]) {
      const x = l1x + tw(B, l1.slice(0, at), fb), w = tw(B, 'MUST', fb), y = c.Y(1353) - fb * 0.12;
      page.drawLine({ start: { x, y }, end: { x: x + w, y }, thickness: fb * 0.07, color: INK });
    }
    c.text('ATTACH RECEIPTS WHERE APPLICABLE FOR PAYMENTS TO BE MADE.', 530, 1373, fb, { font: B, align: 'center' });

    // ---- filled values
    const F = { color: FILL };
    c.text(d.nameLine, 488, 193, 11, { ...F, maxPx: 345 });
    c.text(d.addr1, 488, 231, 11, { ...F, maxPx: 345 });
    c.text(d.addr2, 488, 271, 11, { ...F, maxPx: 345 });
    c.text(d.ni, 392, 310, 11, { ...F, maxPx: 182 });
    c.text(d.vehicle, 697, 308, 11, { ...F, maxPx: 145 });
    await c.image(doc, d.signature, 186, 593, 470, 638);
    c.text(d.signedDate, 530, 625, 11, { ...F, maxPx: 210 });
    c.text(d.weDate, 694, 901, 10, { ...F, maxPx: 190 });

    const money = (v) => (v === '' || v === null || v === undefined || isNaN(v) ? '' : Number(v).toFixed(2));
    const cell = (note, amount, a, b, m, y) => {
      if (note) c.text(note, mid(a, m), y, 7.5, { ...F, align: 'center', maxPx: m - a - 6, minSize: 4.5 });
      if (amount !== '' && amount !== undefined) c.text(money(amount), mid(m, b), y, 7.5, { ...F, align: 'center', maxPx: b - m - 4 });
    };
    (d.rows || []).forEach((r, i) => {
      if (!r) return;
      const y = rows[i + 1] + 23;
      c.text(r.place, cols[1] + 4, y, 7.5, { ...F, maxPx: cols[2] - cols[1] - 8, minSize: 4.5 });
      if (r.uk) c.tick(mid(cols[2], subs[0]), y - 7, 20);
      if (r.eu) c.tick(mid(subs[0], cols[3]), y - 7, 20);
      cell(r.parkingNote, r.parking, cols[3], cols[4], subs[1], y);
      cell(r.tollsNote, r.tolls, cols[4], cols[5], subs[2], y);
      cell(r.marketNote, r.market, cols[5], cols[6], subs[3], y);
      cell('', r.vat, cols[6], cols[7], subs[4], y);
      cell('', r.total, cols[7], cols[8], subs[5], y);
    });
    const t = d.totals || {}, ty = rows[8] + 23;
    if (t.uk) c.text(String(t.uk), mid(cols[2], subs[0]), ty, 10, { ...F, align: 'center' });
    if (t.eu) c.text(String(t.eu), mid(subs[0], cols[3]), ty, 10, { ...F, align: 'center' });
    cell('', t.parking, cols[3], cols[4], subs[1], ty);
    cell('', t.tolls, cols[4], cols[5], subs[2], ty);
    cell('', t.market, cols[5], cols[6], subs[3], ty);
    cell('', t.vat, cols[6], cols[7], subs[4], ty);
    cell('', t.total, cols[7], cols[8], subs[5], ty);
    if (t.total) c.text(money(t.total), 318, 1310, 12, F);
  }

  // ---- attachments ---------------------------------------------------------
  async function attach(doc, fonts, att) {
    if (att.kind === 'pdf') {
      const src = await PDFDocument.load(att.bytes, { ignoreEncryption: true });
      const pages = await doc.copyPages(src, src.getPageIndices());
      pages.forEach((p) => doc.addPage(p));
      return;
    }
    const img = att.mime === 'image/png' ? await doc.embedPng(att.bytes) : await doc.embedJpg(att.bytes);
    const land = img.width > img.height * 1.15, size = land ? A4L : A4P;
    const page = doc.addPage(size), m = 28, capH = att.caption ? 18 : 0;
    const k = Math.min((size[0] - 2 * m) / img.width, (size[1] - 2 * m - capH) / img.height);
    const w = img.width * k, h = img.height * k;
    page.drawImage(img, { x: (size[0] - w) / 2, y: m + (size[1] - 2 * m - capH - h) / 2, width: w, height: h });
    if (att.caption) page.drawText(att.caption.replace(/[^\x20-\x7E\xA0-\xFF£]/g, ''), { x: m, y: size[1] - m - 10, size: 10, font: fonts.bold, color: INK });
  }

  async function build(data, opts = {}) {
    const doc = await PDFDocument.create();
    doc.setTitle('Weekly Timesheet' + (data.p1 && data.p1.weekCommencing ? ' - w/c ' + data.p1.weekCommencing : ''));
    doc.setCreator('Tacho Timesheet');
    const fonts = {
      reg: await doc.embedFont(StandardFonts.Helvetica),
      bold: await doc.embedFont(StandardFonts.HelveticaBold),
      times: await doc.embedFont(StandardFonts.TimesRoman),
      timesBold: await doc.embedFont(StandardFonts.TimesRomanBold),
    };
    await page1(doc, fonts, data.p1 || {});
    if (opts.page2 !== false) await page2(doc, fonts, data.p2 || {});
    for (const a of data.attachments || []) {
      try { await attach(doc, fonts, a); } catch (e) { console.warn('attachment failed', a.name, e); }
    }
    return doc.save();
  }

  const api = { build };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.TimesheetPDF = api;
})(typeof self !== 'undefined' ? self : globalThis);
