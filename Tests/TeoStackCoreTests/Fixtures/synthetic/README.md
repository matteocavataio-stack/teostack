# File sintetici

Questi file NON vengono da una camera: li costruisce lo script `make_*.py` seguendo il formato descritto nei sorgenti di ExifTool
(`Image::ExifTool::Red`). I file `*.exiftool.json` sono l'output REALE di `exiftool -json -G1 -n` (ExifTool 12.76) su di essi, filtrato sul gruppo `Red`.
Servono a verificare che il lettore nativo dia gli stessi valori di ExifTool; NON dimostrano che un file R3D vero venga letto allo stesso modo.
Quando ci saranno file veri, metterli in `/fixtures` (i test relativi si attivano da soli).
