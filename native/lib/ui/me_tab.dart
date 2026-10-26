// Me: your details, signature, how the timesheet is filled, saved areas, email wording, backup.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';
import '../core/week.dart' show todayKey;
import '../data/pdf_service.dart';
import '../data/store.dart';
import 'common.dart';
import 'receipts.dart' show tempFile;

class MeTab extends StatelessWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: store, builder: (context, _) {
        final p = store.profile;
        void setP(String k, dynamic v) { p[k] = v; store.changed(); }
        Widget choice(String k, String label, Map<String, String> opts, {String def = 'yes'}) => DropdownButtonFormField<String>(
              initialValue: opts.containsKey(p[k]) ? p[k] as String : def, decoration: InputDecoration(labelText: label),
              items: [for (final o in opts.entries) DropdownMenuItem(value: o.key, child: Text(o.value))], onChanged: (v) => setP(k, v),
            );
        const yn = {'yes': 'Yes', 'no': 'No'};
        return Scaffold(
          appBar: AppBar(title: const Row(children: [TukiMark(size: 30), SizedBox(width: 10), Text('Me', style: TextStyle(fontWeight: FontWeight.w800))])),
          body: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Your details (on the timesheet)'),
              SyncedField(label: 'Name (page 1)', value: (p['name'] ?? '').toString(), hint: store.card != null ? '${store.card!.identification.surname} ${store.card!.identification.firstNames}' : '', onChanged: (v) => setP('name', v)),
              const SizedBox(height: 10),
              SyncedField(label: 'Name in block letters (page 2)', value: (p['nameLine'] ?? '').toString(), onChanged: (v) => setP('nameLine', v)),
              const SizedBox(height: 10),
              SyncedField(label: 'Address line 1', value: (p['addr1'] ?? '').toString(), onChanged: (v) => setP('addr1', v)),
              const SizedBox(height: 10),
              SyncedField(label: 'Address line 2', value: (p['addr2'] ?? '').toString(), onChanged: (v) => setP('addr2', v)),
              const SizedBox(height: 10),
              SyncedField(label: 'National Insurance number', value: (p['ni'] ?? '').toString(), onChanged: (v) => setP('ni', v)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: choice('declaration', 'Declaration answer', const {'': '—', 'YES': 'YES', 'NO': 'NO'}, def: '')),
                const SizedBox(width: 8),
                Expanded(child: choice('page2', 'Include page 2', yn)),
              ]),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionTitle('Signature', trailing: Text(store.signatureBytes == null ? 'not set yet' : 'saved', style: TextStyle(color: mutedColor(context)))),
              if (store.signatureBytes != null)
                Container(height: 90, padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: Image.memory(store.signatureBytes!, fit: BoxFit.contain)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                FilledButton.icon(icon: const Icon(Icons.draw_outlined, size: 18), label: Text(store.signatureBytes == null ? 'Sign' : 'Sign again'), onPressed: () async {
                  final png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SignaturePad()));
                  if (png != null) store.signatureBytes = png;
                }),
                OutlinedButton.icon(icon: const Icon(Icons.photo_outlined, size: 18), label: const Text('From a photo'), onPressed: () async {
                  final f = await pickOne(type: FileType.image);
                  if (f == null) return;
                  final png = signatureFromPhoto(f.bytes);
                  if (png == null) { if (context.mounted) alert(context, 'Could not find a signature in that photo.'); return; }
                  store.signatureBytes = png;
                }),
                if (store.signatureBytes != null) TextButton(onPressed: () => store.signatureBytes = null, child: const Text('Remove')),
              ]),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Fill in from the tacho'),
              for (final o in fillOptions.entries)
                CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: store.on(o.key), title: Text(o.value),
                    onChanged: (v) => setP('fill', {...((p['fill'] ?? {}) as Map), o.key: v ?? true})),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Settings'),
              choice('geocode', 'Look up place names on the map', yn),
              const SizedBox(height: 10),
              choice('learn', 'Remember names you type for GPS spots', yn),
              const SizedBox(height: 10),
              SyncedField(label: 'Night out when the day ends more than … km from base', value: '${store.awayKm.round()}', keyboard: TextInputType.number,
                  onChanged: (v) { final n = double.tryParse(v); if (n != null && n > 0) setP('awayKm', n); }),
              const SizedBox(height: 10),
              choice('dropWord', 'Write "Drop" before drop names', yn, def: 'no'),
              const SizedBox(height: 10),
              choice('hereAlerts', 'Tell me when I arrive at a starred place', yn),
              const SizedBox(height: 10),
              choice('nearTacho', '"Were you here?" also from tacho GPS', yn),
              const SizedBox(height: 10),
              choice('autoRead', 'Read totals from receipt photos', yn),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Saved areas'),
              Text('Places the timesheet names by GPS. The base is home (for nights out).', style: TextStyle(color: mutedColor(context), fontSize: 13)),
              if (store.places.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('None yet. Load a card file, then type a name into a start/finish place.', style: TextStyle(color: mutedColor(context)))),
              for (final pl in store.places)
                Padding(key: ValueKey(pl['id']), padding: const EdgeInsets.only(top: 10), child: Row(children: [
                  IconButton(tooltip: 'Base (home)', icon: Icon(pl['base'] == true ? Icons.home : Icons.home_outlined, color: pl['base'] == true ? const Color(0xFF1D7A46) : null),
                      onPressed: () { for (final q in store.places) { q['base'] = identical(q, pl); } store.changed(); }),
                  Expanded(flex: 3, child: SyncedField(value: (pl['name'] ?? '').toString(),
                      hint: (store.geoCache[geoKey(numOf(pl['lat']), numOf(pl['lon']))]?['label'] ?? '${numOf(pl['lat']).toStringAsFixed(4)}, ${numOf(pl['lon']).toStringAsFixed(4)}').toString(),
                      onChanged: (v) { pl['name'] = v.trim(); store.changed(); })),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: SyncedField(value: '${(pl['radius'] as num?)?.round() ?? 500}', hint: 'm', keyboard: TextInputType.number,
                      onChanged: (v) { pl['radius'] = int.tryParse(v) ?? 500; store.changed(); })),
                  IconButton(icon: const Icon(Icons.close), onPressed: () { store.places.remove(pl); store.changed(); }),
                ])),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionTitle('Email', trailing: TextButton(onPressed: () { p.remove('emailTpl'); p.remove('emailSubjTpl'); store.changed(); }, child: const Text('Reset'))),
              SyncedField(label: 'Subject', value: (p['emailSubjTpl'] ?? AppStore.defaultSubject).toString(), onChanged: (v) => setP('emailSubjTpl', v)),
              const SizedBox(height: 10),
              SyncedField(label: 'Message', maxLines: 8, value: (p['emailTpl'] ?? AppStore.defaultEmail).toString(), onChanged: (v) => setP('emailTpl', v)),
              const SizedBox(height: 6),
              Text('You can use {name} {firstName} {cardName} {weekCommencing} {weekEnding} {wc} {we} {vehicle} {days} {nights} {expenses} {daysList} {file}',
                  style: TextStyle(color: mutedColor(context), fontSize: 12)),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Backup'),
              Text('Everything is saved on this phone. Keep a copy now and then (receipt photos are not in the copy).', style: TextStyle(color: mutedColor(context), fontSize: 13)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                FilledButton.tonalIcon(icon: const Icon(Icons.upload_file, size: 18), label: const Text('Save a copy'), onPressed: () async {
                  final f = await tempFile('tuki-data-${todayKey()}.json', Uint8List.fromList(utf8.encode(store.exportAll())));
                  await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: 'Tuki backup'));
                }),
                OutlinedButton.icon(icon: const Icon(Icons.download, size: 18), label: const Text('Restore / import from web app'), onPressed: () async {
                  final f = await pickOne();
                  if (f == null) return;
                  try { store.importAll(utf8.decode(f.bytes)); if (context.mounted) toast(context, '✓ Imported'); }
                  catch (e) { if (context.mounted) alert(context, 'That file could not be read: $e'); }
                }),
                if (((p['hiddenStops'] ?? const []) as List).isNotEmpty)
                  TextButton(onPressed: () { p.remove('hiddenStops'); store.changed(); }, child: Text('Show ${(p['hiddenStops'] as List).length} removed suggestions again')),
                TextButton(onPressed: () async {
                  final f = await tempFile('TC_timesheet_blank.pdf', await buildBlankPdf());
                  await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')]));
                }, child: const Text('Blank timesheet PDF')),
              ]),
            ]))),
            Padding(padding: const EdgeInsets.all(16), child: Text('Tuki · native Android app · made for drivers', textAlign: TextAlign.center, style: TextStyle(color: mutedColor(context), fontSize: 12))),
          ]),
        );
      });
}

// ---- signature ---------------------------------------------------------------------------------
/// Crop to the ink, keep transparency.
Uint8List? trimToInk(img.Image im) {
  var x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
  for (final px in im) {
    if (px.a > 20) { if (px.x < x0) x0 = px.x; if (px.x > x1) x1 = px.x; if (px.y < y0) y0 = px.y; if (px.y > y1) y1 = px.y; }
  }
  if (x1 < 0) return null;
  const pad = 6;
  final c = img.copyCrop(im, x: (x0 - pad).clamp(0, im.width), y: (y0 - pad).clamp(0, im.height),
      width: (x1 - x0 + 1 + pad * 2).clamp(1, im.width), height: (y1 - y0 + 1 + pad * 2).clamp(1, im.height));
  return img.encodePng(c);
}

/// Photo of a signature on paper: paper → transparent, ink → blue-black.
Uint8List? signatureFromPhoto(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (im.width > 900) im = img.copyResize(im, width: 900);
  final out = img.Image(width: im.width, height: im.height, numChannels: 4);
  for (final px in im) {
    final l = (px.r + px.g + px.b) / 3, a = ((200 - l) * 2.2).clamp(0, 255).round();
    out.setPixelRgba(px.x, px.y, 15, 30, 110, a);
  }
  return trimToInk(out);
}

class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key});
  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  final strokes = <List<Offset>>[];
  Size size = Size.zero;

  Future<void> save() async {
    if (strokes.every((s) => s.length < 2)) { alert(context, 'Sign in the box first.'); return; }
    const k = 2.0; // draw at double size for a crisp signature
    final rec = ui.PictureRecorder(), c = Canvas(rec);
    c.scale(k);
    _SigPainter(strokes).paint(c, size);
    final image = await rec.endRecording().toImage((size.width * k).round(), (size.height * k).round());
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final im = img.Image.fromBytes(width: image.width, height: image.height, bytes: data!.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    final png = trimToInk(im);
    if (mounted) Navigator.pop(context, png);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in the box'), actions: [
          TextButton(onPressed: () => setState(strokes.clear), child: const Text('Clear', style: TextStyle(color: Colors.white))),
          TextButton(onPressed: save, child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        ]),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFD5DCEA))),
            child: LayoutBuilder(builder: (context, box) {
              size = box.biggest;
              return GestureDetector(
                onPanStart: (d) => setState(() => strokes.add([d.localPosition])),
                onPanUpdate: (d) => setState(() => strokes.last.add(d.localPosition)),
                child: CustomPaint(painter: _SigPainter(strokes), size: Size.infinite),
              );
            }),
          ),
        ),
      );
}

class _SigPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  _SigPainter(this.strokes);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFF0F2A80)..strokeWidth = 4..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length; i++) { path.lineTo(s[i].dx, s[i].dy); }
      canvas.drawPath(path, p);
    }
  }
  @override
  bool shouldRepaint(_) => true;
}
