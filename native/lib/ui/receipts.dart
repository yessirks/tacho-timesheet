// Receipts: scan with Google's on-device document scanner (finds the paper, straightens it, several pages
// for long receipts), read the total with on-device text recognition, or attach a photo / PDF.
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import '../core/receipt.dart';
import '../data/store.dart';
import 'common.dart';

/// Long receipt in parts: stack them top to bottom at the same width, as one JPEG.
Uint8List _stack(List<Uint8List> parts) {
  if (parts.length == 1) return parts.first;
  final ims = parts.map((p) => img.decodeImage(p)!).toList();
  final w = ims.map((i) => i.width).reduce((a, b) => a > b ? a : b).clamp(1, 1800);
  final scaled = ims.map((i) => img.copyResize(i, width: w)).toList();
  final out = img.Image(width: w, height: scaled.fold(0, (a, i) => a + i.height));
  img.fill(out, color: img.ColorRgb8(255, 255, 255));
  var y = 0;
  for (final s in scaled) { img.compositeImage(out, s, dstY: y); y += s.height; }
  return img.encodeJpg(out, quality: 88);
}

/// Shrinks a photo to at most 1800 px and saves it as JPEG.
Uint8List _shrink(Uint8List bytes) {
  final i = img.decodeImage(bytes);
  if (i == null) throw 'Could not open that photo.';
  final o = img.bakeOrientation(i);
  final k = 1800 / (o.width > o.height ? o.width : o.height);
  return img.encodeJpg(k < 1 ? img.copyResize(o, width: (o.width * k).round()) : o, quality: 85);
}

Future<ReceiptInfo?> readReceipt(String path) async {
  final r = TextRecognizer(script: TextRecognitionScript.latin);
  try { return parseReceipt((await r.processImage(InputImage.fromFilePath(path))).text); } catch (_) { return null; } finally { await r.close(); }
}

/// Scan a receipt into `e` (an expense). Returns a short summary of what was read, or null when cancelled.
Future<String?> scanInto(BuildContext context, J e) async {
  final scanner = DocumentScanner(options: DocumentScannerOptions(documentFormats: {DocumentFormat.jpeg}, mode: ScannerMode.full, pageLimit: 4, isGalleryImport: true));
  try {
    final res = await scanner.scanDocument();
    final paths = res.images ?? const <String>[];
    if (paths.isEmpty) return null;
    final bytes = _stack([for (final p in paths) await File(p).readAsBytes()]);
    store.removeAttachment(e);
    e['att'] = {...await store.saveAttachment(bytes, 'receipt-scan.jpg', 'image/jpeg'), 'scanned': true};
    store.changed();
    return await _autoRead(e, store.attFile(e['att'])!.path);
  } catch (err) {
    // Keep it short: the first line of the error, not the whole Java stack.
    final why = (err is PlatformException ? (err.message ?? err.code) : '$err').split('\n').first;
    if (context.mounted) alert(context, "The scanner couldn't start ($why). You can still attach a photo with the 📎 button.");
    return null;
  } finally {
    await scanner.close();
  }
}

/// Attach a photo or PDF from the phone to `e` (an expense, or an "other" attachment holder).
Future<String?> attachInto(BuildContext context, J e, {bool read = true}) async {
  final f = await pickOne(type: FileType.custom, extensions: ['jpg', 'jpeg', 'png', 'heic', 'webp', 'pdf']);
  if (f == null) return null;
  final isPdf = f.ext == 'pdf';
  try {
    final bytes = isPdf ? f.bytes : _shrink(f.bytes);
    store.removeAttachment(e);
    e['att'] = await store.saveAttachment(bytes, f.name, isPdf ? 'application/pdf' : 'image/jpeg');
    store.changed();
    if (!isPdf && read) return await _autoRead(e, store.attFile(e['att'])!.path);
    return '';
  } catch (err) {
    if (context.mounted) alert(context, '$err${RegExp('hei[cf]', caseSensitive: false).hasMatch(f.name) ? ' HEIC photos need to be JPG.' : ''}');
    return null;
  }
}

/// Reads the total from the receipt already attached to `e`.
Future<String> autoReadInto(J e) async { final f = store.attFile(e['att']); return f == null ? '' : _autoRead(e, f.path); }

/// "Read total" fills an empty amount / VAT, and the type when it's obvious.
Future<String> _autoRead(J e, String path) async {
  if (store.profile['autoRead'] == 'no') return '';
  final info = await readReceipt(path);
  if (info == null || info.empty) return "Couldn't read a total, please type it in.";
  final said = <String>[], fresh = money(e['amount']) == 0;
  if (info.kind != null && fresh && info.kind != e['type']) { e['type'] = info.kind; said.add(expenseTypes[info.kind]!); }
  if (info.amount != null && fresh) { e['amount'] = info.amount!.toStringAsFixed(2); said.add('£${e['amount']}'); }
  if (info.vat != null && money(e['vat']) == 0) { e['vat'] = info.vat!.toStringAsFixed(2); said.add('VAT £${e['vat']}'); }
  store.changed();
  return said.isEmpty ? '' : 'Read ${said.join(', ')}';
}

/// Small thumbnail of an attachment; tap to view.
class AttThumb extends StatelessWidget {
  final Map att;
  const AttThumb(this.att, {super.key});
  @override
  Widget build(BuildContext context) {
    final f = store.attFile(att);
    final child = att['kind'] == 'pdf' || f == null || !f.existsSync()
        ? Container(width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.red.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
            child: Text(att['kind'] == 'pdf' ? 'PDF' : '?', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)))
        : ClipRRect(borderRadius: BorderRadius.circular(8), child: RotatedBox(quarterTurns: _turns(att), child: Image.file(f, width: 44, height: 44, fit: BoxFit.cover, cacheWidth: 120)));
    return InkWell(onTap: () => viewAttachment(context, att), child: child);
  }
}

int _turns(Map att) => (((att['rot'] as num?) ?? 0).toInt() % 360) ~/ 90;

Future<void> viewAttachment(BuildContext context, Map att) async {
  final f = store.attFile(att);
  if (f == null || !await f.exists() || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _Viewer(att: att, file: f)));
}

/// Full-screen receipt (photo, or every page of a PDF) with buttons to turn it the right way up.
class _Viewer extends StatefulWidget {
  final Map att; final File file;
  const _Viewer({required this.att, required this.file});
  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  final pages = <Uint8List>[];
  @override
  void initState() {
    super.initState();
    if (widget.att['kind'] == 'pdf') {
      widget.file.readAsBytes().then((b) async {
        await for (final p in Printing.raster(b, dpi: 72)) { final png = await p.toPng(); if (mounted) setState(() => pages.add(png)); }
      });
    }
  }
  void turn(int deg) { widget.att['rot'] = ((((widget.att['rot'] as num?) ?? 0).toInt() + deg) % 360 + 360) % 360; store.changed(); setState(() {}); }
  @override
  Widget build(BuildContext context) {
    final q = _turns(widget.att);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.att['name'] ?? 'Receipt'), actions: [
        IconButton(tooltip: 'Turn left', icon: const Icon(Icons.rotate_left), onPressed: () => turn(-90)),
        IconButton(tooltip: 'Turn right', icon: const Icon(Icons.rotate_right), onPressed: () => turn(90)),
      ]),
      body: widget.att['kind'] == 'pdf'
          ? ListView(padding: const EdgeInsets.all(12), children: [
              if (pages.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())),
              for (final p in pages) Padding(padding: const EdgeInsets.only(bottom: 12), child: RotatedBox(quarterTurns: q, child: Image.memory(p))),
            ])
          : InteractiveViewer(maxScale: 6, child: Center(child: RotatedBox(quarterTurns: q, child: Image.file(widget.file)))),
      bottomNavigationBar: const SafeArea(child: Padding(padding: EdgeInsets.all(12),
          child: Text('Turn it so the writing reads the right way. The timesheet uses a portrait or landscape page to match.', style: TextStyle(color: Colors.white70), textAlign: TextAlign.center))),
    );
  }
}

/// Temp file helper for sharing.
Future<File> tempFile(String name, Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}
