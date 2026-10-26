// Receipts: scan with Google's on-device document scanner (finds the paper, straightens it, several pages
// for long receipts), read the total with on-device text recognition, or attach a photo / PDF.
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
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
    if (context.mounted) alert(context, 'The scanner could not start: $err');
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
        : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(f, width: 44, height: 44, fit: BoxFit.cover, cacheWidth: 120));
    return InkWell(onTap: () => viewAttachment(context, att), child: child);
  }
}

Future<void> viewAttachment(BuildContext context, Map att) async {
  final f = store.attFile(att);
  if (f == null || !await f.exists()) return;
  if (!context.mounted) return;
  if (att['kind'] == 'pdf') { toast(context, 'PDF receipts are added to the timesheet as pages.'); return; }
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
        backgroundColor: Colors.black, appBar: AppBar(title: Text(att['name'] ?? 'Receipt')),
        body: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(f))),
      )));
}

/// Temp file helper for sharing.
Future<File> tempFile(String name, Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}
