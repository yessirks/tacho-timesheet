TRUKIA
======

Online (PC or phone): https://yessirks.github.io/tacho-timesheet/

Or double-click index.html (opens in Chrome / Edge). Nothing is uploaded: the .ddd file,
your details and photos stay in this browser on this device.

Tabs (opens on the Map)
-----------------------
Timesheet   pick the week, check the days, add expenses/receipts, download or share the PDF,
            copy the email to the office.
Diary       a calendar. Write each day's start place, finish place, and a list of
            Drop / Pickup / Couple / Uncouple + name (e.g. Drop · Torquay Sainsbury's),
            plus that day's expenses (parking, tolls, food, other) with receipt photos.
            When you load the .ddd, your diary goes straight into the timesheet and the
            tacho fills in the rest (times, driving hours, nights out, missing places).
            Bold = written by you, grey = from the tacho, green dot = tacho activity.
Places      starred places: exact spots like the gate of a drop, with a note (gate, bay…).
            "＋ Add place": search a name or postcode, or paste coordinates (📋), then nudge
            the pin onto the gate on the satellite map. Or "Star where I am".
            One tap opens Google Maps, Waze or TomTom. Export GPX (TomTom, Garmin) or
            KML (Google My Maps), import them back. Also the saved place names and Base.
My details  name, address, NI number, declaration, signature, presets (what to fill from
            the tacho, email wording), saved places, and your data (download/restore).

Weekly use
----------
1. During the week: Diary tab, tap the day, add places, drops/pickups (with trailer number)
   and expenses. 📍 finds where you are and suggests the place ("Sainsbury's Paignton"),
   ⭐ starred spots first. 📷 Scan: 1) crop (auto edges, magnifier on the corners, rotate),
   2) enhance (Colour / Greyscale / B&W / Original, brightness, contrast, "＋ Add part" for a
   long receipt, "🔍 Read total" fills the amount and VAT), then Save;
   📎 File adds a photo or PDF you already have. Tap names you've used before; hold one to
   rename it everywhere, remove it from the list, or star it. Typing in any place box
   suggests your ⭐ starred spots first (picking one also saves its exact position).
   On a phone: swipe left/right to change day, or use the week strip.
   Trailers: "+ Couple", type the trailer number once; every drop after it (also on the next
   days) shows 🚛 that trailer until you uncouple ("✂ Uncouple" in the banner). Drops are numbered.
   The name box learns your routes ("Usually next"), and "↻ Same as another day" copies a run.
2. Download your driver card (.ddd) and load it ("Load .ddd file", or drop it on the page).
3. Timesheet tab: pick the week, check it, add expenses ("Add photo" attaches the receipt).
4. Download PDF (or Share on a phone): timesheet, subsistence claim, then the receipts.
   The badge next to the button shows "✓ Downloaded <date>" (orange if you changed the week
   after downloading), and sent weeks get a ✓ in the week list.
   Food goes in the form's "Market expenses" column (the form has no food column).
5. Copy the subject (e.g. "Weekly Timesheet - Smith John(18/10)") and the email,
   paste them into your email to the office, attach the PDF. Change both in Me > Presets.

First time only
---------------
My details tab: fill in name, address, NI number, sign, and check the Base place
(home/depot; nights out = the day ended more than 25 km from Base).

Your data
---------
Everything is saved automatically in this browser's storage on this device (like cookies,
but bigger), and stays there until you clear the browser's site data.
My details > "Download my data (.json)" saves a copy of everything: details, signature,
presets, places, diary, your edits and expenses (receipt photos aren't included; they're
in the PDFs). "Restore from a .json file" loads it back, e.g. on your phone or a new PC.
Restoring merges: it never deletes what's already on the device.
On iPhone, add the app to the Home Screen, otherwise Safari may clear it after a few weeks unused.

Android app (APK)
-----------------
Download https://github.com/yessirks/tacho-timesheet/releases/download/trukia-latest/Trukia.apk
on the phone and open it to install. It's the same app, full-screen, and updates itself with the
website. Built by .github/workflows/android.yml; the signing key lives in Desktop\Trukia-signing-key
(keep it safe: updates must be signed with the same key).

On your phone (without the APK)
-------------------------------
Open the link in Chrome (Android) or Safari (iPhone), then "Install app" / "Add to Home Screen".
It then works offline like an app. Get the .ddd onto the phone (card reader app, email, Drive…),
tap "Load .ddd file", and use "Share" to send the PDF and the email text to the office.

Receipts are read automatically
-------------------------------
No account or API key needed: the reader runs in the browser (first use downloads it).
After you scan or add a receipt photo it fills the empty amount and VAT and fixes the type
(parking / toll / food). Turn it off in Me > Presets if you prefer.

Where the data comes from
-------------------------
- Start time = card inserted, finish time = last activity (same as reading the tacho).
- Start/finish place = your diary, otherwise the GPS position the tacho stores when you
  start/end the day (only when it's exact). Names come from your saved places, a few built-in
  sites, then OpenStreetMap. Type your own name once (e.g. "Kepak Merthyr") and it's reused.
- Drops = your diary, otherwise the tacho's Load/Unload GPS entries (only if you press
  Load/Unload on the tachograph). "Stops with work" times are shown to jog your memory.

Files
-----
index.html, app.js  the app       tacho.js  .ddd reader     week.js  builds the week
form.js             draws the PDF  TC_timesheet_blank.pdf   the empty form
