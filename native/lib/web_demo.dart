// Sample data for the browser preview build only (the phone app starts empty or from your backup).
const webDemo = '''{
 "profile": {"name": "SAMPLE DRIVER", "hereAlerts": "no"},
 "places": [{"id": "b1", "name": "Scorrier yard", "lat": 50.2550, "lon": -5.2000, "radius": 1500, "base": true}],
 "stars": [
  {"id": "s1", "name": "Sainsbury's Paignton - goods in", "note": "Gate 2 on Torquay Rd, ring bell", "lat": 50.4362, "lon": -3.5699},
  {"id": "s2", "name": "Gordano Services lorry park", "note": "Overnight, pay at kiosk", "lat": 51.4762, "lon": -2.7080},
  {"id": "s3", "name": "Trewithen Dairy", "note": "Bay 4, reverse in", "lat": 50.4434, "lon": -4.6394}
 ],
 "diary": {
  "2026-10-26": {"start": "Scorrier yard", "finish": "Gordano Services", "stops": [
    {"type": "couple", "name": "Scorrier yard", "ref": "4471"},
    {"type": "drop", "name": "Sainsbury's Paignton", "lat": 50.4362, "lon": -3.5699},
    {"type": "drop", "name": "Tesco Exeter"}]},
  "2026-10-23": {"start": "Scorrier yard", "finish": "Scorrier yard", "stops": [
    {"type": "pickup", "name": "Trewithen Dairy", "lat": 50.4434, "lon": -4.6394},
    {"type": "drop", "name": "Sainsbury's Paignton"}]}
 },
 "weeks": {"week:2026-10-25": {"days": [{},{},{},{},{},{},{}], "foot": {}, "expenses": [
   {"id": "e1", "day": 1, "type": "parking", "note": "Gordano", "amount": "28.50", "vat": "4.75"}], "other": []}}
}''';
