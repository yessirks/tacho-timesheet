// Pick the total, VAT, date and kind of expense out of receipt text (from on-device OCR). Port of scan.js parseReceipt.
import 'dart:math' as math;

class ReceiptInfo {
  final double? amount, vat; final String? date, kind;
  const ReceiptInfo({this.amount, this.vat, this.date, this.kind});
  bool get empty => amount == null && vat == null;
}

final _oBeforeDigit = RegExp(r'[Oo](?=\d)|(?<=\d)[Oo]');
final _moneyRe = RegExp(r'£?\s?(\d{1,4})[.,](\d{2})(?!\d|%)');
List<double> _money(String l) => _moneyRe.allMatches(l.replaceAll(_oBeforeDigit, '0')).map((m) => double.parse('${m[1]}.${m[2]}')).toList();

final _ranks = [
  (RegExp(r'total\s*(to\s*pay|due|paid)|amount\s*due|balance\s*due|to\s*pay|grand\s*total', caseSensitive: false), 3),
  (RegExp(r'\btotal\b', caseSensitive: false), 2),
  (RegExp(r'\b(sale|card|visa|mastercard|debit|contactless|amount|received|paid)\b', caseSensitive: false), 1),
];

ReceiptInfo parseReceipt(String text) {
  final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  double? total; var totalRank = -1;
  for (final l in lines) {
    if (RegExp(r'sub\s*-?\s*total|vat|net\b|change|tip', caseSensitive: false).hasMatch(l)) continue;
    final a = _money(l);
    if (a.isEmpty) continue;
    for (final (re, r) in _ranks) {
      if (re.hasMatch(l) && (r > totalRank || (r == totalRank && a.last > total!))) { total = a.last; totalRank = r; break; }
    }
  }
  final all = lines.expand(_money).where((v) => v > 0 && v < 5000).toList();
  if (total == null && all.isNotEmpty) total = all.reduce(math.max);
  double? vat;
  if (total != null) {
    final t = total;
    final cands = lines.where((l) => RegExp('vat', caseSensitive: false).hasMatch(l)).expand(_money).where((v) => v > 0 && v < t * 0.3).toList();
    final twenty = cands.where((v) => (v - t / 6).abs() <= 0.02).firstOrNull; // 20% VAT included in the total
    vat = twenty ?? (cands.isNotEmpty ? cands.reduce(math.max) : null);
  }
  final dm = RegExp(r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b').firstMatch(text);
  final date = dm == null ? null : '${dm[1]!.padLeft(2, '0')}/${dm[2]!.padLeft(2, '0')}/${dm[3]!.length == 2 ? '20${dm[3]}' : dm[3]}';
  // What kind of expense it looks like.
  final kind = RegExp(r'parking|car ?park|lorry ?park|truck ?stop|overnight|\bsnap\b', caseSensitive: false).hasMatch(text) ? 'parking'
      : RegExp(r'\b(toll|bridge|crossing|dart ?charge|tunnel)', caseSensitive: false).hasMatch(text) ? 'tolls'
      : RegExp(r'\b(meal|coffee|tea|sandwich|food|breakfast|lunch|dinner|greggs|mcdonald|costa|subway|burger|kfc|caf[eé]|restaurant|starbucks|drink|pasty|baguette|wrap)\b', caseSensitive: false).hasMatch(text) ? 'food'
      : null;
  return ReceiptInfo(amount: total, vat: vat, date: date, kind: kind);
}
