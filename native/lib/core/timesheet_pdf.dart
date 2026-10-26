// Draws the Conway Bailey weekly timesheet (page 1) and subsistence/expenses claim (page 2)
// as clean vector pages, fills them, and appends receipt images. Port of form.js.
// Layout numbers are in "scan pixels" measured from the original paper form and mapped to A4.
import 'dart:typed_data';
import 'package:pdf/pdf.dart';

const _ink = PdfColor(0, 0, 0);
const _fill = PdfColor(0.06, 0.17, 0.5); // filled-in values: dark blue, like a biro
const _a4l = PdfPageFormat(841.89, 595.28), _a4p = PdfPageFormat(595.28, 841.89);

class P1Day {
  final String startTime, finishTime, startPlace, finishPlace, drops, nightOut, driving;
  const P1Day({this.startTime = '', this.finishTime = '', this.startPlace = '', this.finishPlace = '', this.drops = '', this.nightOut = '', this.driving = ''});
}

class P1Data {
  final String name, weekCommencing, totalWeekdays, totalWeekendDays, away24, declaration;
  final List<P1Day> days;
  final Uint8List? signature;
  const P1Data({this.name = '', this.weekCommencing = '', this.days = const [], this.totalWeekdays = '', this.totalWeekendDays = '',
      this.away24 = '', this.declaration = '', this.signature});
}

class P2Row {
  final String place, parkingNote, tollsNote, marketNote;
  final bool uk, eu;
  final double? parking, tolls, market, vat, total; // null = leave blank
  const P2Row({this.place = '', this.uk = false, this.eu = false, this.parking, this.parkingNote = '', this.tolls, this.tollsNote = '',
      this.market, this.marketNote = '', this.vat, this.total});
}

class P2Totals {
  final int uk, eu; final double? parking, tolls, market, vat, total;
  const P2Totals({this.uk = 0, this.eu = 0, this.parking, this.tolls, this.market, this.vat, this.total});
}

class P2Data {
  final String nameLine, addr1, addr2, ni, vehicle, signedDate, weDate;
  final Uint8List? signature;
  final List<P2Row> rows;
  final P2Totals totals;
  const P2Data({this.nameLine = '', this.addr1 = '', this.addr2 = '', this.ni = '', this.vehicle = '', this.signedDate = '', this.weDate = '',
      this.signature, this.rows = const [], this.totals = const P2Totals()});
}

/// A receipt or other page to append: an image (JPEG/PNG) with an optional caption.
class Attachment { final Uint8List bytes; final String caption; const Attachment(this.bytes, [this.caption = '']); }

class _Fonts { final PdfFont reg, bold, times, timesBold; _Fonts(this.reg, this.bold, this.times, this.timesBold); }

final _quotes = RegExp('[‘’]'), _dquotes = RegExp('[“”]'), _dashes = RegExp('[–—]');
final _notLatin = RegExp(r'[^\x20-\x7E\xA0-\xFF£]'), _notLatinNl = RegExp(r'[^\x20-\x7E\xA0-\xFF\n£]');
String _clean(String t) => t.replaceAll(_quotes, "'").replaceAll(_dquotes, '"').replaceAll(_dashes, '-').replaceAll(_notLatin, '');

double _tw(PdfFont f, String t, double size) => t.isEmpty ? 0 : f.stringMetrics(t).advanceWidth * size;

class _Ctx {
  final PdfDocument doc; final PdfPage page; final PdfGraphics g; final _Fonts fonts;
  final double s, cx, cy, ox, oy, h;
  _Ctx(this.doc, this.page, this.fonts, {required this.s, required this.cx, required this.cy, required this.ox, required this.oy})
      : g = page.getGraphics(), h = page.pageFormat.height;

  double X(double px) => ox + (px - cx) * s;
  double Y(double py) => h - (oy + (py - cy) * s);
  double S(double px) => px * s;
  double width(String t, PdfFont f, double size) => _tw(f, t, size);
  /// Font size so that `t` spans `spanPx` scan pixels.
  double sizeFor(String t, PdfFont f, double spanPx) => S(spanPx) / _tw(f, t, 1);

  void _str(PdfFont f, double size, String t, double x, double y, PdfColor c) {
    g.setFillColor(c);
    g.drawString(f, size, t, x, y);
  }

  void _line(double x1, double y1, double x2, double y2, double th, PdfColor c, {PdfLineCap cap = PdfLineCap.butt, List<num> dash = const []}) {
    g.setStrokeColor(c); g.setLineWidth(th); g.setLineCap(cap); g.setLineDashPattern(dash);
    g.moveTo(x1, y1); g.lineTo(x2, y2); g.strokePath();
    if (dash.isNotEmpty) g.setLineDashPattern();
  }

  double text(String? t0, double px, double py, double size, {PdfFont? font, PdfColor color = _ink, String align = 'left', double? maxPx, double? minSize, bool underline = false}) {
    if (t0 == null) return 0;
    var t = _clean(t0);
    if (t.isEmpty) return 0;
    final f = font ?? fonts.reg;
    var sz = size;
    if (maxPx != null) { final w = _tw(f, t, sz); if (w > S(maxPx)) sz = sz * S(maxPx) / w; }
    if (minSize != null && sz < minSize) { // still too long: truncate
      sz = minSize;
      while (t.length > 1 && _tw(f, t, sz) > S(maxPx!)) { t = t.substring(0, t.length - 1); }
    }
    final w = _tw(f, t, sz);
    var x = X(px);
    if (align == 'center') { x -= w / 2; } else if (align == 'right') { x -= w; }
    // Word by word, so spacing follows our metrics and not the viewer's substitute font.
    var wx = x;
    for (final m in RegExp(r'( +)|([^ ]+)').allMatches(t)) {
      final part = m[0]!;
      if (part[0] != ' ') _str(f, sz, part, wx, Y(py), color);
      wx += _tw(f, part, sz);
    }
    if (underline) _line(x, Y(py) - sz * 0.12, x + w, Y(py) - sz * 0.12, sz * 0.06, color);
    return w;
  }

  // Justified line: stretch word gaps so the line spans x1..x2.
  void justify(String t, double x1, double x2, double py, double size, PdfFont f) {
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final total = words.fold(0.0, (a, w) => a + _tw(f, w, size));
    final gap = (S(x2 - x1) - total) / (words.length - 1);
    var x = X(x1);
    for (final w in words) { _str(f, size, w, x, Y(py), _ink); x += _tw(f, w, size) + gap; }
  }

  void line(double x1, double y1, double x2, double y2, [double th = 1.4]) => _line(X(x1), Y(y1), X(x2), Y(y2), S(th), _ink);
  void dots(double x1, double x2, double py) => _line(X(x1), Y(py), X(x2), Y(py), 0.7, _ink, cap: PdfLineCap.round, dash: const [0.01, 1.9]);
  void rect(double x1, double y1, double x2, double y2, double th) { line(x1, y1, x2, y1, th); line(x2, y1, x2, y2, th); line(x2, y2, x1, y2, th); line(x1, y2, x1, y1, th); }

  void tick(double cx, double cy, double hpx, [PdfColor color = _fill]) {
    final k = S(hpx);
    final p = [[X(cx) - k * 0.45, Y(cy) + k * 0.05], [X(cx) - k * 0.1, Y(cy) - k * 0.4], [X(cx) + k * 0.5, Y(cy) + k * 0.55]];
    _line(p[0][0], p[0][1], p[1][0], p[1][1], 1.3, color, cap: PdfLineCap.round);
    _line(p[1][0], p[1][1], p[2][0], p[2][1], 1.3, color, cap: PdfLineCap.round);
  }

  // Ellipse around a word whose baseline is py.
  void circle(double x1, double x2, double py, [PdfColor color = _fill]) {
    final ccx = (X(x1) + X(x2)) / 2, w = (X(x2) - X(x1)) / 2 + S(5), hh = S(13);
    g.setStrokeColor(color); g.setLineWidth(1.1); g.setLineCap(PdfLineCap.butt);
    g.drawEllipse(ccx, Y(py) + S(6), w, hh); g.strokePath();
  }

  // Wrapped text inside a box; shrinks the font until it fits.
  void box(String? t, double x1, double y1, double x2, double y2, double size, {PdfFont? font, PdfColor color = _fill}) {
    if (t == null || t.isEmpty) return;
    final f = font ?? fonts.reg, maxW = S(x2 - x1), maxH = S(y2 - y1);
    final paras = t.replaceAll(_notLatinNl, '').split('\n');
    var sz = size; var lines = <String>[];
    for (; sz >= 5; sz -= 0.25) {
      lines = [];
      for (final para in paras) {
        var cur = '';
        for (final w in para.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
          final tryLine = cur.isNotEmpty ? '$cur $w' : w;
          if (_tw(f, tryLine, sz) <= maxW || cur.isEmpty) { cur = tryLine; } else { lines.add(cur); cur = w; }
        }
        if (cur.isNotEmpty) lines.add(cur);
      }
      if (lines.length * sz * 1.18 <= maxH && lines.every((l) => _tw(f, l, sz) <= maxW)) break;
    }
    final lh = sz * 1.18, top = Y(y1) - sz * 0.95;
    for (var i = 0; i < lines.length; i++) { _str(f, sz, lines[i], X(x1), top - i * lh, color); }
  }

  void image(Uint8List? bytes, double x1, double y1, double x2, double y2) {
    if (bytes == null || bytes.isEmpty) return;
    final img = PdfImage.file(doc, bytes: bytes);
    final bw = S(x2 - x1), bh = S(y2 - y1), k = (bw / img.width) < (bh / img.height) ? bw / img.width : bh / img.height;
    final w = img.width * k, hh = img.height * k;
    g.drawImage(img, X(x1) + (bw - w) / 2, Y(y2) + (bh - hh) / 2, w, hh);
  }
}

// ---- page 1: weekly timesheet -------------------------------------------------
const _p1Cols = [105.0, 213.0, 457.0, 865.0, 1210.0, 1298.0, 1387.0];
const _p1Top = 110.0, _p1Head = 148.0, _p1RowH = 100.57;
const _p1Days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

void _page1(PdfDocument doc, _Fonts fonts, P1Data d, Uint8List? logo) {
  final page = PdfPage(doc, pageFormat: _a4l);
  final c = _Ctx(doc, page, fonts, s: 0.57, cx: 746, cy: 526, ox: _a4l.width / 2, oy: _a4l.height / 2);
  final b = fonts.bold, r = fonts.reg, cols = _p1Cols;
  const bottom = _p1Head + _p1RowH * 7;

  // header
  final hs = c.sizeFor('Weekly Timesheet', b, 146);
  c.text('Name:', 104, 66, hs, font: b);
  c.line(157, 72, 600, 72, 1.1);
  c.text('Weekly Timesheet', 676, 70, hs, font: b);
  c.text('Week Commening: Sunday', 893, 72, hs, font: b);
  c.line(1105, 78, 1390, 78, 1.1);

  // table grid
  c.rect(cols[0], _p1Top, cols[6], bottom, 2.2);
  c.line(cols[0], _p1Head, cols[6], _p1Head, 1.8);
  for (var i = 1; i < 6; i++) { c.line(cols[i], _p1Top, cols[i], bottom, i >= 4 ? 1.6 : 1.8); }
  for (var row = 1; row < 7; row++) { c.line(cols[0], _p1Head + row * _p1RowH, cols[6], _p1Head + row * _p1RowH, 1.6); }

  c.image(logo, 117, 114, 200, 143);
  final th = c.sizeFor('Start and Finish Times', b, 175);
  c.text('Start and Finish Times', (cols[1] + cols[2]) / 2, 140, th, font: b, align: 'center');
  c.text('Start and Finish Place', (cols[2] + cols[3]) / 2, 141, th, font: b, align: 'center');
  c.text('Drops', (cols[3] + cols[4]) / 2, 144, th, font: b, align: 'center');
  final sm = c.sizeFor('Night Out (UK', b, 80);
  c.text('Night Out (UK', (cols[4] + cols[5]) / 2, 127, sm, font: b, align: 'center');
  c.text('or EU)', (cols[4] + cols[5]) / 2, 145, sm, font: b, align: 'center');
  c.text('No of Driving', (cols[5] + cols[6]) / 2, 127, sm, font: b, align: 'center');
  c.text('Hours used', (cols[5] + cols[6]) / 2, 145, sm, font: b, align: 'center');

  final ds = c.sizeFor('Wednesday', b, 92), ls = c.sizeFor('Finish Time:', r, 92);
  for (var i = 0; i < 7; i++) {
    final t = _p1Head + i * _p1RowH, y1 = t + 42, y2 = t + 92;
    c.text(_p1Days[i], (cols[0] + cols[1]) / 2, y1, ds, font: b, align: 'center');
    c.text('Start Time:', 220, y1, ls); c.line(310, y1 + 4, 427, y1 + 4, 1); c.text('hrs', 428, y1, ls);
    c.text('Finish Time:', 220, y2, ls); c.line(316, y2 + 4, 427, y2 + 4, 1); c.text('hrs', 428, y2, ls);
    c.text('Start Place:', 461, y1, ls); c.line(549, y1 + 5, 862, y1 + 5, 1);
    c.text(i == 3 ? 'finish Place:' : 'Finish Place:', 461, y2, ls); c.line(558, y2 + 5, 862, y2 + 5, 1);

    final v = i < d.days.length ? d.days[i] : const P1Day();
    const fs = 11.5;
    c.text(v.startTime, 369, y1 - 2, fs, color: _fill, align: 'center', maxPx: 112);
    c.text(v.finishTime, 372, y2 - 2, fs, color: _fill, align: 'center', maxPx: 108);
    c.text(v.startPlace, 556, y1 - 2, 10.5, color: _fill, maxPx: 302, minSize: 6.5);
    c.text(v.finishPlace, 565, y2 - 2, 10.5, color: _fill, maxPx: 294, minSize: 6.5);
    c.box(v.drops, cols[3] + 6, t + 6, cols[4] - 5, t + _p1RowH - 4, 9.5);
    if (v.nightOut.isNotEmpty) {
      c.tick((cols[4] + cols[5]) / 2 - 14, t + 50, 26);
      c.text(v.nightOut, (cols[4] + cols[5]) / 2 + 14, t + 60, 8, color: _fill, align: 'center');
    }
    c.text(v.driving, (cols[5] + cols[6]) / 2, t + 60, 10.5, color: _fill, align: 'center', maxPx: 84);
  }

  // footer
  const decl = 'Declaration : I declare that I have not had any accidents/caused and damage/failed to return paperwork or failed to make myself available for work';
  final fsz = c.sizeFor(decl, b, 1176);
  c.text(decl, 107, 873, fsz, font: b);
  c.text('YES/NO', 1313, 876, fsz, font: b);
  const by = 920.0;
  c.text('have worked the following:', 109, by - 2, fsz, font: b);
  c.text('Total Weekdays', 349, by, fsz, font: b); c.line(481, by + 2, 529, by + 2, 1);
  c.text('Total Weekend Days', 559, by + 1, fsz, font: b); c.line(727, by + 3, 786, by + 3, 1);
  c.text('24hr Away from home', 815, by + 2, fsz, font: b);
  final yw = c.width('YES/', b, fsz) / 0.57, yesW = c.width('YES', b, fsz) / 0.57, noW = c.width('NO', b, fsz) / 0.57;
  c.text('YES/NO', 996, by + 2, fsz, font: b);
  c.text('Signed:', 1110, by + 4, fsz, font: b); c.line(1170, by + 6, 1388, by + 6, 1);
  c.text('Conway Bailey Transport Ltd 2015', 746, 1004, c.sizeFor('Conway Bailey Transport Ltd 2015', r, 267), align: 'center');

  // filled footer values
  c.text(d.totalWeekdays, 505, by - 3, 12, color: _fill, align: 'center');
  c.text(d.totalWeekendDays, 756, by - 2, 12, color: _fill, align: 'center');
  if (d.away24 == 'YES') { c.circle(996, 996 + yesW, by + 2); } else if (d.away24 == 'NO') { c.circle(996 + yw, 996 + yw + noW, by + 2); }
  if (d.declaration == 'YES') { c.circle(1313, 1313 + yesW, 876); } else if (d.declaration == 'NO') { c.circle(1313 + yw, 1313 + yw + noW, 876); }
  c.image(d.signature, 1175, by - 36, 1385, by + 6);
  c.text(d.name, 165, 63, 12, color: _fill, maxPx: 432);
  c.text(d.weekCommencing, 1110, 70, 12, color: _fill, maxPx: 278);
}

// ---- page 2: subsistence claim + expenses ---------------------------------------
const _p2Cols = [124.3, 191.7, 304.8, 407.9, 515.7, 620.2, 729.5, 831.1, 936.6];
const _p2Subs = [356.1, 461.5, 568.4, 674.8, 780.8, 884.3];
const _p2Rows = [933.7, 997.8, 1033.4, 1070.0, 1104.2, 1138.9, 1172.6, 1206.8, 1241.5, 1277.1];
const _p2Split = 978.3;
const _p2Days = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

void _page2(PdfDocument doc, _Fonts fonts, P2Data d) {
  final page = PdfPage(doc, pageFormat: _a4p);
  final c = _Ctx(doc, page, fonts, s: 0.551, cx: 530.5, cy: 764, ox: _a4p.width / 2, oy: _a4p.height / 2);
  final r = fonts.times, b = fonts.timesBold;

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
  final bs = c.sizeFor(body[0][0], r, 811) * 0.995;
  final hsz = c.sizeFor('EMPLOYEES NAME (BLOCK LETTERS)', r, 296);

  c.text('TO: CONWAY BAILEY TRANSPORT LTD', 126, 181, hsz, font: r);
  c.text('EMPLOYEES NAME (BLOCK LETTERS)', 126, 201, hsz, font: r);
  c.dots(482, 836, 198);
  c.text('PERMANENT ADDRESS', 126, 239, hsz, font: r);
  c.dots(482, 836, 236);
  c.dots(482, 836, 276);
  c.text('NATIONAL INSURANCE NUMBER', 126, 316, hsz, font: r);
  c.dots(388, 576, 316);
  c.text('VEHICLE NO', 594, 314, hsz, font: r);
  c.dots(691, 842, 314);

  const baselines = [[352.0, 374.0, 396.0], [437.0, 459.0], [499.0, 522.0, 544.0], [585.0]];
  for (var i = 0; i < body.length; i++) {
    for (var j = 0; j < body[i].length; j++) {
      if (j < body[i].length - 1) { c.justify(body[i][j], 126, 937, baselines[i][j], bs, r); } else { c.text(body[i][j], 126, baselines[i][j], bs, font: r); }
    }
  }
  c.text('Signed', 124, 630, bs, font: r); c.dots(183, 476, 630);
  c.text('Date', 484, 630, bs, font: r); c.dots(524, 741, 630);

  c.text('EMPLOYERS CERTIFICATE', 532, 672, c.sizeFor('EMPLOYERS CERTIFICATE', b, 211), font: b, align: 'center');
  final es = bs * 1.07;
  const e1a = 'I certify that the permanent address given by Mr.', e1b = 'is his normal place of';
  c.text(e1a, 124, 715, es, font: r);
  c.dots(c.width(e1a, r, es) / 0.551 + 130, 745, 715);
  c.text(e1b, 937, 715, es, font: r, align: 'right');
  c.justify('residence and that to the best of my knowledge this claim for tax free subsistence allowance satisfies', 124, 937, 738, es, r);
  c.text('the requirement of the Inland Revenue.', 124, 761, es, font: r);
  c.text('Signed', 124, 806, es, font: r); c.dots(186, 437, 806);
  c.text('(Transport Manager)', 440, 806, es, font: r);
  c.text('Date', 662, 806, es, font: r); c.dots(705, 905, 806);

  final ws = c.sizeFor('EMPLOYEE/EMPLOYER OR BOTH LIABLE TO PROSECUTION BY THE INLAND REVENUE.', r, 690);
  c.text('WARNING:', 124, 846, ws, font: r, underline: true);
  c.justify('A FALSE DECLARATION ON THIS CERTIFICATE MAY RENDER THE', 124 + c.width('WARNING:', r, ws) / 0.551 + 28, 937, 846, ws, r);
  c.text('EMPLOYEE/EMPLOYER OR BOTH LIABLE TO PROSECUTION BY THE INLAND REVENUE.', 124, 866, ws, font: r);

  c.text('EXPENSES', 472, 906, c.sizeFor('EXPENSES', b, 94), font: b, align: 'center');
  c.text('W/E DATE', 605, 906, ws, font: r); c.dots(688, 886, 906);

  // expenses grid
  final cols = _p2Cols, subs = _p2Subs, rows = _p2Rows;
  c.rect(cols[0], rows[0], cols[8], rows[9], 1.4);
  for (var i = 1; i < 8; i++) { c.line(cols[i], rows[0], cols[i], rows[9], 1.3); }
  for (var k = 1; k < 9; k++) { c.line(cols[0], rows[k], cols[8], rows[k], 1.3); }
  c.line(cols[2], _p2Split, cols[3], _p2Split, 1.2);
  c.line(subs[0], _p2Split, subs[0], rows[9], 1.2);
  for (var i = 1; i < subs.length; i++) { c.line(subs[i], rows[1], subs[i], rows[9], 1.2); }
  final ts = c.sizeFor('EXPENSES', r, 94) * 0.98;
  double mid(double a, double bb) => (a + bb) / 2;
  c.text('PLACE', mid(cols[1], cols[2]), 972, ts, font: r, align: 'center');
  c.text('NIGHTS', mid(cols[2], cols[3]), 951, ts, font: r, align: 'center');
  c.text('OUT', mid(cols[2], cols[3]), 972, ts, font: r, align: 'center');
  c.text('UK', mid(cols[2], subs[0]), 993, ts * 0.8, font: r, align: 'center');
  c.text('EU', mid(subs[0], cols[3]), 993, ts * 0.8, font: r, align: 'center');
  c.text('PARKING', mid(cols[3], cols[4]), 972, ts, font: r, align: 'center');
  c.text('BRIDGE/', mid(cols[4], cols[5]), 961, ts, font: r, align: 'center');
  c.text('TOLLS', mid(cols[4], cols[5]), 982, ts, font: r, align: 'center');
  c.text('MARKET', mid(cols[5], cols[6]), 961, ts, font: r, align: 'center');
  c.text('EXPENSES', mid(cols[5], cols[6]), 982, ts, font: r, align: 'center');
  c.text('VAT', mid(cols[6], cols[7]), 971, ts, font: r, align: 'center');
  c.text('TOTAL', mid(cols[7], cols[8]), 971, ts, font: r, align: 'center');
  for (var i = 0; i < 7; i++) { c.text(_p2Days[i], mid(cols[0], cols[1]), rows[i + 1] + 24, ts, font: r, align: 'center'); }
  c.text('TOTALS', mid(cols[1], cols[2]), rows[8] + 24, ts, font: r, align: 'center');

  c.text('EXPENSES', 181, 1313, ws * 1.05, font: r);
  c.text('£', 302, 1312, ws * 1.05, font: r);
  c.dots(485, 770, 1312);
  c.text('AUTHORISED BY', 771, 1312, ws * 1.05, font: r);
  final fb = c.sizeFor('ATTACH RECEIPTS WHERE APPLICABLE FOR PAYMENTS TO BE MADE.', b, 595);
  const l1 = 'ALL PARKING MUST BE AUTHORISED BY THE OFFICE PRIOR TO UNDERTAKING.  YOU MUST';
  final l1w = c.text(l1, 530, 1353, fb, font: b, align: 'center'), l1x = c.X(530) - l1w / 2;
  for (final at in [l1.indexOf('MUST'), l1.lastIndexOf('MUST')]) {
    final x = l1x + _tw(b, l1.substring(0, at), fb), w = _tw(b, 'MUST', fb), y = c.Y(1353) - fb * 0.12;
    c._line(x, y, x + w, y, fb * 0.07, _ink);
  }
  c.text('ATTACH RECEIPTS WHERE APPLICABLE FOR PAYMENTS TO BE MADE.', 530, 1373, fb, font: b, align: 'center');

  // ---- filled values
  c.text(d.nameLine, 488, 193, 11, color: _fill, maxPx: 345);
  c.text(d.addr1, 488, 231, 11, color: _fill, maxPx: 345);
  c.text(d.addr2, 488, 271, 11, color: _fill, maxPx: 345);
  c.text(d.ni, 392, 310, 11, color: _fill, maxPx: 182);
  c.text(d.vehicle, 697, 308, 11, color: _fill, maxPx: 145);
  c.image(d.signature, 186, 593, 470, 638);
  c.text(d.signedDate, 530, 625, 11, color: _fill, maxPx: 210);
  c.text(d.weDate, 694, 901, 10, color: _fill, maxPx: 190);

  String money(double? v) => v == null ? '' : v.toStringAsFixed(2);
  void cell(String note, double? amount, double a, double bb, double m, double y) {
    if (note.isNotEmpty) c.text(note, mid(a, m), y, 7.5, color: _fill, align: 'center', maxPx: m - a - 6, minSize: 4.5);
    if (amount != null) c.text(money(amount), mid(m, bb), y, 7.5, color: _fill, align: 'center', maxPx: bb - m - 4);
  }
  for (var i = 0; i < d.rows.length && i < 7; i++) {
    final row = d.rows[i], y = rows[i + 1] + 23;
    c.text(row.place, cols[1] + 4, y, 7.5, color: _fill, maxPx: cols[2] - cols[1] - 8, minSize: 4.5);
    if (row.uk) c.tick(mid(cols[2], subs[0]), y - 7, 20);
    if (row.eu) c.tick(mid(subs[0], cols[3]), y - 7, 20);
    cell(row.parkingNote, row.parking, cols[3], cols[4], subs[1], y);
    cell(row.tollsNote, row.tolls, cols[4], cols[5], subs[2], y);
    cell(row.marketNote, row.market, cols[5], cols[6], subs[3], y);
    cell('', row.vat, cols[6], cols[7], subs[4], y);
    cell('', row.total, cols[7], cols[8], subs[5], y);
  }
  final t = d.totals, ty = rows[8] + 23;
  if (t.uk > 0) c.text('${t.uk}', mid(cols[2], subs[0]), ty, 10, color: _fill, align: 'center');
  if (t.eu > 0) c.text('${t.eu}', mid(subs[0], cols[3]), ty, 10, color: _fill, align: 'center');
  cell('', t.parking, cols[3], cols[4], subs[1], ty);
  cell('', t.tolls, cols[4], cols[5], subs[2], ty);
  cell('', t.market, cols[5], cols[6], subs[3], ty);
  cell('', t.vat, cols[6], cols[7], subs[4], ty);
  cell('', t.total, cols[7], cols[8], subs[5], ty);
  if (t.total != null) c.text(money(t.total), 318, 1310, 12, color: _fill);
}

// ---- attachments -------------------------------------------------------------------
void _attach(PdfDocument doc, _Fonts fonts, Attachment att) {
  final img = PdfImage.file(doc, bytes: att.bytes);
  final land = img.width > img.height * 1.15, size = land ? _a4l : _a4p;
  final page = PdfPage(doc, pageFormat: size), g = page.getGraphics();
  const m = 28.0;
  final capH = att.caption.isNotEmpty ? 18.0 : 0.0;
  final k1 = (size.width - 2 * m) / img.width, k2 = (size.height - 2 * m - capH) / img.height, k = k1 < k2 ? k1 : k2;
  final w = img.width * k, h = img.height * k;
  g.drawImage(img, (size.width - w) / 2, m + (size.height - 2 * m - capH - h) / 2, w, h);
  if (att.caption.isNotEmpty) { g.setFillColor(_ink); g.drawString(fonts.bold, 10, att.caption.replaceAll(_notLatin, ''), m, size.height - m - 10); }
}

/// Builds the PDF. Attachments that fail to decode are skipped.
Future<Uint8List> buildTimesheet({P1Data p1 = const P1Data(), P2Data p2 = const P2Data(), bool page2 = true,
    List<Attachment> attachments = const [], Uint8List? logo}) async {
  final doc = PdfDocument();
  PdfInfo(doc, title: 'Weekly Timesheet${p1.weekCommencing.isNotEmpty ? ' - w/c ${p1.weekCommencing}' : ''}', creator: 'Tuki', producer: 'Tuki');
  final fonts = _Fonts(PdfFont.helvetica(doc), PdfFont.helveticaBold(doc), PdfFont.times(doc), PdfFont.timesBold(doc));
  _page1(doc, fonts, p1, logo);
  if (page2) _page2(doc, fonts, p2);
  for (final a in attachments) {
    try { _attach(doc, fonts, a); } catch (_) { /* skip a broken image */ }
  }
  return doc.save();
}
