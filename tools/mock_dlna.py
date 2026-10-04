"""Mock DLNA server for testing Resonance without a real NAS.

Runs on any machine with Python 3 (Windows/Mac/Linux):
    python3 tools/mock_dlna.py --port 8899
Then point the app (Add NAS manually) at:
    http://<your-lan-ip>:8899/desc.xml
Or validate from Windows PowerShell:
    .\\tools\\Test-DLNA.ps1 -LocationUrl "http://127.0.0.1:8899/desc.xml"

Serves: device description, ContentDirectory Browse (2 folders + 2 sample
tracks that stream tiny generated WAVs), and album art placeholder.
Sample audio is synthesized sine-wave WAVs so no copyrighted files needed.
"""
from __future__ import annotations

import argparse
import io
import math
import struct
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

DESC_XML = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Resonance Mock NAS</friendlyName>
    <manufacturer>Resonance Test</manufacturer>
    <modelName>MockDLNA</modelName>
    <UDN>uuid:mock-nas-1234</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
        <controlURL>/control</controlURL>
        <eventSubURL>/events</eventSubURL>
        <SCPDURL>/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>"""


def make_wav(seconds: float = 3.0, freq: float = 440.0) -> bytes:
    buf = io.BytesIO()
    rate = 22050
    n = int(rate * seconds)
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        for i in range(n):
            v = int(12000 * math.sin(2 * math.pi * freq * i / rate))
            w.writeframes(struct.pack("<h", v))
    return buf.getvalue()


TRACKS = [
    {"id": "t1", "title": "Mock Sine A", "artist": "Test Artist", "album": "Mock NAS", "file": "a.wav", "dur": "0:00:03"},
    {"id": "t2", "title": "Mock Sine E", "artist": "Test Artist", "album": "Mock NAS", "file": "b.wav", "dur": "0:00:03"},
]


def didl(base: str, object_id: str) -> str:
    if object_id == "0":
        return f"""<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
<container id="music" parentID="0" childCount="2" restricted="1"><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Music</dc:title><upnp:class xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">object.container</upnp:class></container>
<container id="fav" parentID="0" childCount="1" restricted="1"><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Favorites</dc:title><upnp:class xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">object.container</upnp:class></container>
</DIDL-Lite>"""
    items = "".join(
        f"""<item id="{t['id']}" parentID="{object_id}" restricted="1">"""
        f"""<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">{t['title']}</dc:title>"""
        f"""<upnp:artist xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">{t['artist']}</upnp:artist>"""
        f"""<upnp:album xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">{t['album']}</upnp:album>"""
        f"""<upnp:class xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">object.item.audioItem.musicTrack</upnp:class>"""
        f"""<res protocolInfo="http-get:*:audio/wav:*" duration="{t['dur']}">{base}/audio/{t['file']}</res></item>"""
        for t in TRACKS
    )
    return f'<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">{items}</DIDL-Lite>'


class Handler(BaseHTTPRequestHandler):
    server_version = "ResonanceMock/1.0"

    def _send(self, body: bytes, ctype: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        host = f"http://{self.headers.get('Host', '127.0.0.1')}"
        if path == "/desc.xml":
            self._send(DESC_XML.encode(), "text/xml")
        elif path == "/audio/a.wav":
            self._send(make_wav(freq=440.0), "audio/wav")
        elif path == "/audio/b.wav":
            self._send(make_wav(freq=659.25), "audio/wav")
        else:
            self.send_error(404, path)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        host = f"http://{self.headers.get('Host', '127.0.0.1')}"
        oid = "0"
        if "<ObjectID>" in body:
            oid = body.split("<ObjectID>")[1].split("</ObjectID>")[0].strip() or "0"
        if oid in ("music", "fav"):
            oid = "music"
        payload = didl(host, oid)
        # NOTE: DIDL is XML-escaped inside <Result>, like real servers
        escaped = payload.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        resp = (
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            "<s:Body><u:BrowseResponse "
            'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
            f"<Result>{escaped}</Result>"
            "<NumberReturned>10</NumberReturned><TotalMatches>10</TotalMatches>"
            "<UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>"
        )
        self._send(resp.encode(), "text/xml")

    def log_message(self, *args: object) -> None:
        print("mock-nas:", *args)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    args = ap.parse_args()
    print(f"Serving mock DLNA at http://0.0.0.0:{args.port}/desc.xml")
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
