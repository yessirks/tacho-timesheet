# Tuki (native)

The native Android version of Tuki, built with Flutter. Same features and the same data format as the
web app in the folder above, so a backup from the web app imports straight in (Me › Backup › Restore).

- `lib/core/` is pure Dart: the tacho card parser, the week logic, the timesheet PDF, link parsing,
  receipt reading. These are line-by-line ports of `tacho.js`, `week.js`, `form.js`, `places.js` and
  `scan.js`, checked against them: same results on a real card, and pixel-identical PDF pages.
- `lib/data/` keeps your data (a JSON file plus receipt files in the app's own folder) and builds the PDF.
- `lib/ui/` holds the four tabs: Map, Diary, Timesheet and Me.

Receipts use Google's on-device document scanner and text recognition (no internet needed).

GitHub Actions builds and signs the APK on every push to `native/` and publishes it as the
`tuki-native-latest` release. Its app id is `io.github.yessirks.tuki`, so it installs next to the web-app Tuki.

Checks: `flutter analyze` and `flutter test`. To compare with the web engine on a card file, set
`TUKI_CARD` and `TUKI_OUT` and run `test/engine_compare_test.dart`.
