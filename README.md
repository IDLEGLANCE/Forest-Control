# Forest Control

Forest Control mit Sirius Rayfield Gen2: Autofarm, Werkzeugautomatik, War-God-Würfe, Auto-Collect, Auto-Sell und Auto-Bossfight.

## Starten

Führe diesen Loader in Potassium aus:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/IDLEGLANCE/Forest-Control/main/Forest-Control-Gen2.luau"))()
```

Der Loader lädt die aktuelle Scriptversion aus diesem Repository. Er ist zusätzlich in `loader.luau` gespeichert.

## Änderungen übernehmen

Der vollständige Quellcode steht in `Forest-Control-Gen2.luau`. Nach einer veröffentlichten Änderung genügt es, den Loader erneut auszuführen. Eine laufende Instanz wird dabei beendet und durch die neue Version ersetzt.

Die Oberfläche und die bisherigen Funktionen bleiben erhalten. Lokale Benutzerkonfigurationen werden nicht in dieses Repository aufgenommen.

## Runs und Weltwechsel

Im Tab **Runs & Event** lädt **Nach Weltwechsel automatisch starten** das Script nach Teleports erneut. Aktuelle Einstellungen, aktive Schalter, Theme und die Bewegungs-Keybinds werden übernommen. Der Executor muss die Teleport-Queue unterstützen; der Status im Tab zeigt die Verfügbarkeit.

- **Raben automatisch einsammeln:** besucht fehlende Raben in freigeschalteten Areas und wartet auf die vom Spiel bestätigte Fundliste.
- **Säulenrätsel automatisch lösen:** startet ab mindestens 90 % geräumter Area 6 und dreht die Säulen anhand der replizierten Zielsymbole. Die Kiste gilt erst bei bestätigtem `Open` als geöffnet.
- **Run automatisch abschließen:** spricht nach geräumten Chapter-Areas und beendetem Guardian-Kampf den Businessman an.
- **Runs automatisch wiederholen:** kehrt nach dem Chapter-Abschluss zur Lobby zurück. In Frozen Wilds reichen alle zwölf bestätigten Raben und die offene Kiste; die Weltschlange ist für diese Wiederholung nicht erforderlich. In der Lobby wird ein freies Pad verwendet und ein neuer Solo-Run mit der gewählten Welt, Schwierigkeit und Friedlich-Einstellung erstellt. Gesperrte oder abgelaufene Welten werden nicht gestartet.

Für wiederholtes Event-Shard-Farmen Raben, Säulenrätsel und Run-Wiederholung einschalten, die Event-Welt auswählen und den Autofarm aktivieren. Auto-Collect und Auto-Boss bleiben separat steuerbar. Die neuen Aktionen pausieren Farmbewegung und Verkauf während ihrer Interaktionen. Alle Optionen können in den nativen Sirius-Configs gespeichert werden.
