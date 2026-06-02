# Animalchain

Mehrseitiges Tierketten-Spiel für GitHub Pages + Supabase.

## Struktur

```text
index.html
practice.html
online.html
local.html
assets/
  styles.css
js/
  app.js
sql/
  required_schema.sql
README.md
```

## JavaScript

Alles JavaScript liegt in einer einzigen Datei:

```text
js/app.js
```

Es gibt keine `config.js`, `database.js`, `practice.js`, `online.js` oder `local.js` mehr.

## Timer im Online-Modus

Der Lobby-Leader kann beim Erstellen einer Lobby den Timer aktivieren.

Denkzeit pro Zug:

- 120 Sekunden
- 60 Sekunden
- 30 Sekunden
- 10 Sekunden

Wenn ein Spieler keine Eingabe innerhalb der Zeit macht, wird er als ausgeschieden markiert und kann nur noch zuschauen.

## Supabase verbinden

Öffne `js/app.js` und trage oben deinen Public/Publishable Key ein:

```js
const ANIMALCHAIN_CONFIG = {
  supabaseUrl: "https://xbncxguszajafewaullp.supabase.co",
  supabaseKey: "DEIN_PUBLIC_PUBLISHABLE_KEY_HIER"
};
```

Nicht eintragen:

- service_role key
- database password
- JWT secret

## Supabase vorbereiten

In Supabase:

```text
SQL Editor
→ New query
→ Inhalt von sql/required_schema.sql einfügen
→ Run
```

## GitHub Pages

Die Dateien müssen direkt im Repository-Root liegen:

```text
index.html
practice.html
online.html
local.html
assets/
js/
sql/
README.md
```
