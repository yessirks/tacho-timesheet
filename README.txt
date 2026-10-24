TACHO TIMESHEET
===============

Online (PC or phone): https://yessirks.github.io/tacho-timesheet/

Or double-click index.html (opens in Chrome / Edge). Nothing is uploaded: the .ddd file,
your details and photos stay in this browser on this device.

Three tabs
----------
Timesheet   pick the week, check the days, add expenses/receipts, download or share the PDF,
            copy the email to the office.
Diary       a calendar. Write each day's start place, finish place and drops as you go.
            When you load the .ddd, your diary goes straight into the timesheet and the
            tacho fills in the rest (times, driving hours, nights out, missing places).
            Bold = written by you, grey = from the tacho, green dot = tacho activity.
My details  name, address, NI number, declaration, signature, presets (what to fill from
            the tacho, email wording), saved places, and your data (download/restore).

Weekly use
----------
1. During the week: Diary tab, tap the day, write places and drops (tap names you've used before).
2. Download your driver card (.ddd) and load it ("Load .ddd file", or drop it on the page).
3. Timesheet tab: pick the week, check it, add expenses ("Add photo" attaches the receipt).
4. Download PDF (or Share on a phone): timesheet, subsistence claim, then the receipts.
5. Copy email, paste it into your email to the office, attach the PDF.

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

On your phone
-------------
Open the link in Chrome (Android) or Safari (iPhone), then "Install app" / "Add to Home Screen".
It then works offline like an app. Get the .ddd onto the phone (card reader app, email, Drive…),
tap "Load .ddd file", and use "Share" to send the PDF and the email text to the office.

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
