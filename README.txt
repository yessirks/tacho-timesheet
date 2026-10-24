TACHO TIMESHEET
===============

Online (PC or phone): https://yessirks.github.io/tacho-timesheet/

Or double-click index.html (opens in Chrome / Edge). Nothing is uploaded: the .ddd file,
your details and photos stay in this browser on this computer.

Weekly use
----------
1. Download your driver card (.ddd) and drop it on the page (or "Load .ddd file").
2. Pick the week (Sunday to Saturday). Times, places, nights out, driving hours,
   vehicle reg and totals are filled from the tacho.
3. Type the drops (and any place names that are missing).
4. Add expenses (parking, tolls). "Add photo" attaches the receipt. "Attach other photo"
   is for things like a bank statement screenshot.
5. Download PDF. You get TC_timesheet_D_M_YY.pdf: timesheet, subsistence claim, then the receipts.

First time only
---------------
- Signature: open "Signature", sign with the mouse/finger (or upload a photo), "Use this signature".
- Page 2: enter address + NI number once; it's remembered.
- Check "Saved places & settings": the Base (home/depot) is detected from where you take
  weekly rests. Nights out = the day ended more than 25 km from Base.

On your phone
-------------
Open https://yessirks.github.io/tacho-timesheet/ in Chrome (Android) or Safari (iPhone), then
"Add to Home screen" / "Install app". It then works offline like an app.
Get the .ddd onto the phone (from your card reader app, email, Drive…), tap "Load .ddd file",
and use "Share" to send the finished PDF to the office (WhatsApp, email…).
Your details, signature and photos are stored on each device separately.
"Back up settings" / "Restore settings" copies them between PC and phone.

Choosing what gets filled in
----------------------------
Under the week picker, untick anything you don't want filled from the tacho
(e.g. driving hours). You can still type those fields by hand.

Where the data comes from
-------------------------
- Start time = card inserted, finish time = last activity (same as reading the tacho).
- Start/finish place = GPS position the tacho stores when you start/end the day
  (only filled when it's exact). Names come from OpenStreetMap; type your own name
  for a place (e.g. "Trewithen Dairy") and it's reused automatically next time.
- Drops: the card only has a GPS position for a drop if you press Load/Unload on the
  tachograph. Do that at each drop and the drops fill themselves in. Otherwise the app
  lists "stops with work" (times) to help you remember them.

Files
-----
index.html, app.js  the app       tacho.js  .ddd reader     week.js  builds the week
form.js             draws the PDF  TC_timesheet_blank.pdf   the empty form
