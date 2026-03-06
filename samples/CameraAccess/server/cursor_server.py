#!/usr/bin/env python3
"""
macOS Cursor Control HTTP Server for Gaze-Based Window Control.

Accepts JSON commands from the iOS app and controls the Mac cursor
using CoreGraphics events. Also provides a /locate endpoint that uses
ORB feature matching between a camera frame and the screen screenshot
to determine where on screen the camera is pointing.

Requires Accessibility permission for Terminal.

Usage:
  pip install flask pyobjc-framework-Quartz opencv-python-headless mss numpy
  python cursor_server.py

Endpoints:
  POST /move     {"x": float, "y": float}
  POST /click    {"x": float, "y": float}
  POST /drag     {"from_x", "from_y", "to_x", "to_y", "steps", "duration"}
  POST /locate   (JPEG body) -> {"status", "x", "y", "matches", "confidence"}
  GET  /position  -> {"x": float, "y": float}
  GET  /screen    -> {"width": int, "height": int}
  GET  /health    -> {"status": "ok"}
"""

import threading
import time

import cv2
import mss
import numpy as np
import Quartz
from flask import Flask, request, jsonify

app = Flask(__name__)


def get_screen_size():
    display_id = Quartz.CGMainDisplayID()
    width = Quartz.CGDisplayPixelsWide(display_id)
    height = Quartz.CGDisplayPixelsHigh(display_id)
    return width, height


def move_mouse(x, y):
    point = Quartz.CGPoint(x, y)
    event = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventMouseMoved, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def click_mouse(x, y):
    point = Quartz.CGPoint(x, y)
    down = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseDown, point, Quartz.kCGMouseButtonLeft
    )
    up = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseUp, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    time.sleep(0.05)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


def mouse_down(x, y):
    point = Quartz.CGPoint(x, y)
    down = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseDown, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)


def mouse_drag_to(x, y):
    point = Quartz.CGPoint(x, y)
    drag = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseDragged, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, drag)


def mouse_up(x, y):
    point = Quartz.CGPoint(x, y)
    up = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseUp, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


def drag_mouse(from_x, from_y, to_x, to_y, steps=20, duration=0.3):
    p0 = Quartz.CGPoint(from_x, from_y)
    down = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseDown, p0, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    time.sleep(0.03)

    step_delay = duration / steps
    for i in range(1, steps + 1):
        t = i / steps
        px = from_x + (to_x - from_x) * t
        py = from_y + (to_y - from_y) * t
        pt = Quartz.CGPoint(px, py)
        drag = Quartz.CGEventCreateMouseEvent(
            None, Quartz.kCGEventLeftMouseDragged, pt, Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, drag)
        time.sleep(step_delay)

    p1 = Quartz.CGPoint(to_x, to_y)
    up = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseUp, p1, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


@app.route("/move", methods=["POST"])
def handle_move():
    data = request.json
    x, y = float(data["x"]), float(data["y"])
    move_mouse(x, y)
    return jsonify({"status": "ok", "action": "move", "x": x, "y": y})


@app.route("/click", methods=["POST"])
def handle_click():
    data = request.json
    x, y = float(data["x"]), float(data["y"])
    click_mouse(x, y)
    return jsonify({"status": "ok", "action": "click", "x": x, "y": y})


@app.route("/drag", methods=["POST"])
def handle_drag():
    data = request.json
    drag_mouse(
        float(data["from_x"]), float(data["from_y"]),
        float(data["to_x"]), float(data["to_y"]),
        steps=int(data.get("steps", 20)),
        duration=float(data.get("duration", 0.3)),
    )
    return jsonify({"status": "ok", "action": "drag"})


@app.route("/mouse_down", methods=["POST"])
def handle_mouse_down():
    data = request.json
    x, y = float(data["x"]), float(data["y"])
    mouse_down(x, y)
    return jsonify({"status": "ok", "action": "mouse_down", "x": x, "y": y})


@app.route("/mouse_drag_to", methods=["POST"])
def handle_mouse_drag_to():
    data = request.json
    x, y = float(data["x"]), float(data["y"])
    mouse_drag_to(x, y)
    return jsonify({"status": "ok", "action": "mouse_drag_to", "x": x, "y": y})


@app.route("/mouse_up", methods=["POST"])
def handle_mouse_up():
    data = request.json
    x, y = float(data["x"]), float(data["y"])
    mouse_up(x, y)
    return jsonify({"status": "ok", "action": "mouse_up", "x": x, "y": y})


@app.route("/position", methods=["GET"])
def handle_position():
    loc = Quartz.NSEvent.mouseLocation()
    screen_h = Quartz.CGDisplayPixelsHigh(Quartz.CGMainDisplayID())
    return jsonify({"x": loc.x, "y": screen_h - loc.y})


@app.route("/screen", methods=["GET"])
def handle_screen():
    w, h = get_screen_size()
    return jsonify({"width": w, "height": h})


@app.route("/health", methods=["GET"])
def handle_health():
    trusted = Quartz.CoreGraphics.CGPreflightPostEventAccess()
    return jsonify({"status": "ok", "accessibility": trusted})


# ---------------------------------------------------------------------------
# Screenshot ORB matching for /locate
# ---------------------------------------------------------------------------

class ScreenshotCache:
    """Caches a screenshot with pre-computed ORB features for fast matching."""

    def __init__(self, refresh_interval=1.0, max_features=2000):
        self.refresh_interval = refresh_interval
        self.max_features = max_features
        self.orb = cv2.ORB_create(nfeatures=max_features)
        self.bf_matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=False)
        self._lock = threading.Lock()
        self._keypoints = None
        self._descriptors = None
        self._last_refresh = 0
        self._screen_w = 0
        self._screen_h = 0
        self._scale_factor = 1.0

    def _refresh_if_needed(self):
        now = time.time()
        if now - self._last_refresh < self.refresh_interval:
            return
        with mss.mss() as sct:
            monitor = sct.monitors[1]  # Primary monitor
            capture_w = monitor["width"]
            capture_h = monitor["height"]
            screenshot = sct.grab(monitor)
            img = np.array(screenshot)[:, :, :3]  # Drop alpha channel
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

        # Detect Retina: mss captures at physical pixels, CGDisplay returns logical
        logical_w = Quartz.CGDisplayPixelsWide(Quartz.CGMainDisplayID())
        scale = capture_w / logical_w if logical_w > 0 else 1.0

        kp, desc = self.orb.detectAndCompute(gray, None)
        with self._lock:
            self._keypoints = kp
            self._descriptors = desc
            self._screen_w = capture_w
            self._screen_h = capture_h
            self._scale_factor = scale
            self._last_refresh = now

    def locate(self, camera_jpeg_bytes, min_matches=15):
        """Match camera JPEG against cached screenshot.

        Returns (screen_x, screen_y, match_count, confidence) in logical
        pixels (matching CGEvent coordinate space), or None on failure.
        """
        self._refresh_if_needed()

        with self._lock:
            if self._descriptors is None or len(self._keypoints) < min_matches:
                return None
            screen_kp = list(self._keypoints)
            screen_desc = self._descriptors.copy()
            scale = self._scale_factor

        # Decode camera JPEG
        nparr = np.frombuffer(camera_jpeg_bytes, np.uint8)
        cam_img = cv2.imdecode(nparr, cv2.IMREAD_GRAYSCALE)
        if cam_img is None:
            return None

        cam_h, cam_w = cam_img.shape[:2]

        # Extract ORB features from camera frame
        cam_kp, cam_desc = self.orb.detectAndCompute(cam_img, None)
        if cam_desc is None or len(cam_kp) < min_matches:
            return None

        # KNN match + Lowe's ratio test
        matches = self.bf_matcher.knnMatch(cam_desc, screen_desc, k=2)
        good = []
        for pair in matches:
            if len(pair) == 2:
                m, n = pair
                if m.distance < 0.75 * n.distance:
                    good.append(m)

        if len(good) < min_matches:
            return None

        src_pts = np.float32([cam_kp[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
        dst_pts = np.float32([screen_kp[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)

        H, mask = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 5.0)
        if H is None:
            return None

        inliers = int(mask.sum()) if mask is not None else 0
        if inliers < min_matches:
            return None

        # Map camera center through homography
        cam_center = np.float32([[cam_w / 2, cam_h / 2]]).reshape(-1, 1, 2)
        screen_pt = cv2.perspectiveTransform(cam_center, H)
        sx = float(screen_pt[0][0][0])
        sy = float(screen_pt[0][0][1])

        # Convert from physical pixels to logical pixels (Retina)
        sx /= scale
        sy /= scale

        # Clamp to logical screen bounds
        logical_w = self._screen_w / scale
        logical_h = self._screen_h / scale
        sx = max(0, min(logical_w, sx))
        sy = max(0, min(logical_h, sy))

        confidence = inliers / len(good) if good else 0.0
        return (sx, sy, inliers, confidence)


screenshot_cache = ScreenshotCache(refresh_interval=1.0, max_features=2000)


@app.route("/locate", methods=["POST"])
def handle_locate():
    content_type = request.content_type or ""
    if "image/jpeg" not in content_type and "application/octet-stream" not in content_type:
        return jsonify({"error": "Content-Type must be image/jpeg"}), 400

    jpeg_data = request.get_data()
    if not jpeg_data or len(jpeg_data) < 100:
        return jsonify({"error": "Empty or invalid JPEG"}), 400

    result = screenshot_cache.locate(jpeg_data, min_matches=15)

    if result is None:
        return jsonify({
            "status": "no_match",
            "x": None,
            "y": None,
            "matches": 0,
            "confidence": 0.0,
        })

    sx, sy, match_count, confidence = result
    return jsonify({
        "status": "ok",
        "x": round(sx, 1),
        "y": round(sy, 1),
        "matches": match_count,
        "confidence": round(confidence, 3),
    })


if __name__ == "__main__":
    w, h = get_screen_size()
    print(f"[CursorServer] Screen: {w}x{h}")
    print(f"[CursorServer] Accessibility: {Quartz.CoreGraphics.CGPreflightPostEventAccess()}")
    print(f"[CursorServer] Starting on http://0.0.0.0:8765")
    app.run(host="0.0.0.0", port=8765, threaded=True)
