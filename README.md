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

Nach Teleports lädt das Script automatisch erneut. Diese Funktion ist fest aktiviert. Aktuelle Einstellungen, aktive Schalter, Theme und die Bewegungs-Keybinds werden übernommen. Der Executor muss die Teleport-Queue unterstützen.

- **Raben automatisch einsammeln:** besucht fehlende Raben in freigeschalteten Areas und wartet auf die vom Spiel bestätigte Fundliste.
- **Säulenrätsel automatisch lösen:** bei freigeschalteter Area 6 priorisiert der aktive Autofarm die sechs vom Spiel markierten Bäume um Runestone 6. Nach dessen bestätigter Aktivierung (`Lit = true`) startet das Rätsel ohne prozentuale Räumungsschwelle; bis zur Kistenöffnung werden keine weiteren Bäume ausgewählt. Die Säulen richten sich nach den replizierten Zielsymbolen; die Kiste gilt erst bei bestätigtem `Open` als geöffnet. Ohne aktiven Autofarm wird der Runestone nicht automatisch freigelegt.
- **Run automatisch abschließen:** spricht nach geräumten Chapter-Areas und beendetem Guardian-Kampf den Businessman an.
- **Runs automatisch wiederholen:** kehrt nach dem Chapter-Abschluss zur Lobby zurück. In Frozen Wilds reichen alle zwölf bestätigten Raben und die offene Kiste; die Weltschlange ist für diese Wiederholung nicht erforderlich. In der Lobby wird ein freies Pad verwendet und ein neuer Solo-Run mit der gewählten Welt, Schwierigkeit und Friedlich-Einstellung erstellt. Gesperrte oder abgelaufene Welten werden nicht gestartet.

Für wiederholtes Event-Shard-Farmen Raben, Säulenrätsel und Run-Wiederholung einschalten, die Event-Welt auswählen und den Autofarm aktivieren. Auto-Collect und Auto-Boss bleiben separat steuerbar. Die neuen Aktionen pausieren Farmbewegung und Verkauf während ihrer Interaktionen. Alle Optionen können in den nativen Sirius-Configs gespeichert werden.

## Automatische Run-Upgrades

Der Tab **Upgrades** verbessert bei eingeschalteter Automatik vorhandene Axt, Kettensäge und Klassenwaffen sowie **Chipper-Speed** und **Grasp** bis zu den im Spiel hinterlegten MAX-Stufen. Preise, Besitz und Levels werden laufend neu gelesen; nach jeder Anfrage wartet die Automatik auf die vom Server bestätigte Stufe. Bei fehlenden Münzen wartet sie auf weiteres Verkaufsgeld. Sie läuft unabhängig vom Autofarm und verwendet die normalen Run-Münzen.

**Axt und Kettensäge automatisch kaufen** ergänzt fehlende Standardwerkzeuge, sobald sie bezahlbar sind und ein freigeschalteter Stand verfügbar ist. Eine vorhandene oder permanente Kettensäge wird nicht erneut gekauft; die Axt bleibt als Ersatz für den bestehenden 85-%-Hitzewechsel vorgesehen. Bei erkannten Klassenwaffen wie War-God-Axt, Hellchain oder Katana entfallen beide Standardkäufe. Normale Werkzeug-Upgrades werden weiterhin für bereits vorhandene Werkzeuge durchgeführt. Die Kaufbewegung pausiert Farm, Sammeln und Verkauf und kehrt anschließend zur Ausgangsposition zurück.

Beide Schalter werden in Configs gespeichert und bei Teleports übernommen. Die Upgrade-Automatik startet standardmäßig ausgeschaltet; der Werkzeugkauf-Schalter wirkt nur bei aktiver Upgrade-Automatik.

## Feste Automatikwerte

Der Basisabstand zum Baum beträgt 2 Studs. Fehlgeschlagene Baumversuche werden nach 5 Sekunden erneut freigegeben; fehlgeschlagene Holz-Sammelversuche nach 2 Sekunden. Diese Werte und der automatische Teleport-Neustart sind fest in der jeweiligen Automatik eingebaut und werden durch alte Config-Einträge nicht verändert. Die Schlagzeiten richten sich nach dem Werkzeug; einen zusätzlichen manuellen Mindestabstand gibt es nicht mehr. Run-, Sammel- und Schusshilfen-Statusanzeigen wurden aus der Oberfläche entfernt.

Bei Axt und Kettensäge führt ein einzelner unbestätigter Treffer nicht sofort zum nächsten Baum: Nach dem nativen Werkzeugtakt sind bis zu zwei weitere Versuche am selben Baum erlaubt. Bestätigte Treffer behalten das schnelle 0,13-Sekunden-Bestätigungsfenster. Erst nach drei aufeinanderfolgenden unbestätigten Treffern greift der normale spätere Baum-Anlauf. Ausschalten, Gebietsgrenzen, Mitspieler und Sägehitze werden weiterhin berücksichtigt.
