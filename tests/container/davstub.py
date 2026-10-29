#!/usr/bin/python3
# Minimal CalDAV stub for the helper test: answers PROPFIND calendar-color for /cal/ and /tasks/ on
# 127.0.0.1:<port> (plain http), only with the fake login testdav / dav-test-pw. Usage: davstub.py <port>
import base64
import http.server
import sys

COLORS = {"/cal/": "#11223344", "/tasks/": "#AABBCC"}   # calendar with alpha (stripped by the helper)
AUTH = "Basic " + base64.b64encode(b"testdav:dav-test-pw").decode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Authorization") != AUTH:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="stub"')
            self.end_headers()
            return
        if self.path not in COLORS:
            self.send_response(404)
            self.end_headers()
            return
        body = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:i="http://apple.com/ns/ical/">'
                '<d:response><d:href>%s</d:href><d:propstat><d:prop><i:calendar-color>%s</i:calendar-color>'
                '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'
                % (self.path, COLORS[self.path])).encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
