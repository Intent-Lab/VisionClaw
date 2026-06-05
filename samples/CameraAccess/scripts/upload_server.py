#!/usr/bin/env python3
"""
Tiny image upload server for VisionClaw.
Accepts JPEG uploads and saves them to ~/.openclaw/media/visionclaw/.
Returns the file path so the agent can read/copy/upload the file.

Usage: python3 upload_server.py [port]
Default port: 18792
"""

import os
import sys
import json
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

SAVE_DIR = Path.home() / ".openclaw" / "media" / "visionclaw"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18792

SAVE_DIR.mkdir(parents=True, exist_ok=True)

class UploadHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/upload":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0 or content_length > 10 * 1024 * 1024:  # 10MB max
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid size"}')
            return

        body = self.rfile.read(content_length)
        filename = f"frame-{int(time.time() * 1000)}.jpg"
        filepath = SAVE_DIR / filename
        filepath.write_bytes(body)

        response = json.dumps({"path": str(filepath), "size": len(body)})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(response.encode())
        print(f"Saved: {filepath} ({len(body)} bytes)")

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","service":"visionclaw-upload"}')

    def log_message(self, format, *args):
        pass  # suppress default logs

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), UploadHandler)
    print(f"VisionClaw upload server listening on port {PORT}")
    print(f"Saving to: {SAVE_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped")
