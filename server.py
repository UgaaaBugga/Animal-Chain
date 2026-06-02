#!/usr/bin/env python3
"""
Mini-Webserver fuer Animalchain.
Wie http.server, aber haengt .html an wenn die Datei sonst nicht gefunden wird.
So funktionieren auch URLs wie /online statt /online.html.

Aufruf:  python server.py [port]
Default-Port: 3000
"""
import http.server
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3000


class SmartHandler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # Erste Aufloesung wie ueblich
        translated = super().translate_path(path)
        # Wenn Datei nicht existiert und kein "/" am Ende und keine Extension,
        # versuche .html dranzuhaengen
        if not os.path.exists(translated):
            base = path.split('?', 1)[0].split('#', 1)[0]
            if not base.endswith('/') and '.' not in base.rsplit('/', 1)[-1]:
                # Probiere mit .html
                alt = super().translate_path(base + '.html')
                if os.path.exists(alt):
                    return alt
        return translated

    def end_headers(self):
        # Verhindere aggressives Caching beim Entwickeln
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self.send_header('Expires', '0')
        # CORS frei - damit lokales Studio (Port 54323) Dateien holen kann
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()


if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    with http.server.ThreadingHTTPServer(('127.0.0.1', PORT), SmartHandler) as httpd:
        print(f'Animalchain laeuft auf http://localhost:{PORT}')
        print(f'Verzeichnis: {os.getcwd()}')
        print('Strg+C zum Beenden.')
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print('\nWebserver gestoppt.')
