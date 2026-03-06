#!/usr/bin/env python3
"""
macOS Cursor Control HTTP Server for Gaze-Based Window Control.

Accepts JSON commands from the iOS app and controls the Mac cursor
using CoreGraphics events. Also provides a /locate endpoint that uses
SuperPoint + LightGlue neural feature matching between a camera frame
and per-monitor screenshots to determine where on screen the camera
is pointing. Works robustly across viewing distances and angles.

Requires Accessibility permission for Terminal.

Usage:
  pip install flask pyobjc-framework-Quartz opencv-python-headless mss numpy torch lightglue
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

import ssl
import threading
import time

ssl._create_default_https_context = ssl._create_unverified_context

import cv2
import mss
import numpy as np
import Quartz
import torch
from flask import Flask, request, jsonify
from lightglue import SuperPoint
from lightglue.utils import numpy_image_to_torch

app = Flask(__name__)


def get_screen_size():
    """Return the bounding box of all displays in logical (point) coordinates.

    Returns (origin_x, origin_y, width, height). The origin can be negative
    when monitors extend to the left of or above the primary display.
    """
    max_displays = 16
    (err, display_ids, count) = Quartz.CGGetActiveDisplayList(max_displays, None, None)
    if err != 0 or count == 0:
        # Fallback to primary
        did = Quartz.CGMainDisplayID()
        return (0, 0, Quartz.CGDisplayPixelsWide(did), Quartz.CGDisplayPixelsHigh(did))

    min_x, min_y = float("inf"), float("inf")
    max_x, max_y = float("-inf"), float("-inf")
    for did in display_ids[:count]:
        bounds = Quartz.CGDisplayBounds(did)
        x, y = bounds.origin.x, bounds.origin.y
        w, h = bounds.size.width, bounds.size.height
        min_x = min(min_x, x)
        min_y = min(min_y, y)
        max_x = max(max_x, x + w)
        max_y = max(max_y, y + h)

    return (int(min_x), int(min_y), int(max_x - min_x), int(max_y - min_y))


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
    ox, oy, w, h = get_screen_size()
    return jsonify({"origin_x": ox, "origin_y": oy, "width": w, "height": h})


@app.route("/health", methods=["GET"])
def handle_health():
    trusted = Quartz.CoreGraphics.CGPreflightPostEventAccess()
    return jsonify({"status": "ok", "accessibility": trusted})


# ---------------------------------------------------------------------------
# SuperPoint + LightGlue neural feature matching for /locate
# ---------------------------------------------------------------------------

_device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
_extractor = SuperPoint(max_num_keypoints=2048).eval().to(_device)

# BFMatcher for kNN ratio test — more robust at varying distances
_bf = cv2.BFMatcher(cv2.NORM_L2)

# Max camera frame dimension (downscale large frames before extraction)
_MAX_CAM_DIM = 960


class ScreenshotCache:
    """Per-monitor screenshot cache with SuperPoint features.

    Uses SuperPoint (learned keypoints, scale/rotation invariant) +
    LightGlue (adaptive neural matcher) for robust matching at any
    viewing distance. Features are extracted per-monitor to avoid
    wasting keypoints on black inter-monitor gaps.
    """

    def __init__(self, refresh_interval=1.0):
        self.refresh_interval = refresh_interval
        self._lock = threading.Lock()
        # List of (monitor_dict, features_dict, retina_scale, feat_scale) per monitor
        self._monitors = []
        self._last_refresh = 0
        self._last_matched_idx = 0  # Prioritize last matched monitor
        self._refreshing = False  # Background refresh flag

    def _refresh_if_needed(self):
        now = time.time()
        if now - self._last_refresh < self.refresh_interval:
            return
        if self._refreshing:
            return  # Already refreshing in background
        self._refreshing = True
        thread = threading.Thread(target=self._do_refresh, daemon=True)
        thread.start()

    def _do_refresh(self):
        try:
            monitors = []
            logical_w = Quartz.CGDisplayPixelsWide(Quartz.CGMainDisplayID())

            with mss.mss() as sct:
                primary_w = sct.monitors[1]["width"] if len(sct.monitors) > 1 else 1
                scale = primary_w / logical_w if logical_w > 0 else 1.0

                for mon in sct.monitors[1:]:  # Skip virtual screen [0]
                    screenshot = sct.grab(mon)
                    img = np.array(screenshot)[:, :, :3]
                    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
                    sh, sw = gray.shape[:2]
                    max_dim = max(sh, sw)
                    feat_scale = 1.0
                    if max_dim > 1600:
                        feat_scale = 1600 / max_dim
                        gray = cv2.resize(gray, (int(sw * feat_scale), int(sh * feat_scale)))
                    tensor = numpy_image_to_torch(gray).to(_device)
                    with torch.no_grad():
                        feats = _extractor.extract(tensor)
                    monitors.append((mon, feats, scale, feat_scale))

            with self._lock:
                self._monitors = monitors
                self._last_refresh = time.time()
        finally:
            self._refreshing = False

    def locate(self, camera_jpeg_bytes, min_matches=15):
        """Match camera JPEG against all monitors using SuperPoint + LightGlue.

        Returns (screen_x, screen_y, match_count, confidence) in global
        CGEvent coordinates, or None on failure.
        """
        self._refresh_if_needed()

        with self._lock:
            if not self._monitors:
                return None
            monitors = list(self._monitors)
            start_idx = self._last_matched_idx

        # Decode camera JPEG and downscale if needed
        nparr = np.frombuffer(camera_jpeg_bytes, np.uint8)
        cam_img = cv2.imdecode(nparr, cv2.IMREAD_GRAYSCALE)
        if cam_img is None:
            return None

        cam_h, cam_w = cam_img.shape[:2]
        max_dim = max(cam_h, cam_w)
        if max_dim > _MAX_CAM_DIM:
            s = _MAX_CAM_DIM / max_dim
            cam_img = cv2.resize(cam_img, (int(cam_w * s), int(cam_h * s)))
            cam_h, cam_w = cam_img.shape[:2]

        t0 = time.time()
        cam_tensor = numpy_image_to_torch(cam_img).to(_device)

        with torch.no_grad():
            cam_feats = _extractor.extract(cam_tensor)

        cam_desc = cam_feats["descriptors"][0].cpu().numpy()
        cam_kps = cam_feats["keypoints"][0].cpu().numpy()

        # Try last matched monitor first; early-exit if confidence is good
        order = [start_idx] + [i for i in range(len(monitors)) if i != start_idx]
        best = None  # (sx, sy, inliers, confidence, idx)

        for idx in order:
            mon, screen_feats, scale, feat_scale = monitors[idx]

            scr_desc = screen_feats["descriptors"][0].cpu().numpy()
            scr_kps = screen_feats["keypoints"][0].cpu().numpy()

            if len(cam_desc) < 2 or len(scr_desc) < 2:
                continue

            raw = _bf.knnMatch(cam_desc, scr_desc, k=2)
            matches = []
            for pair in raw:
                if len(pair) == 2:
                    m, n = pair
                    if m.distance < 0.85 * n.distance:
                        matches.append(m)

            n_matches = len(matches)
            if n_matches < min_matches:
                continue

            src_pts = cam_kps[[m.queryIdx for m in matches]].reshape(-1, 1, 2)
            dst_pts = scr_kps[[m.trainIdx for m in matches]].reshape(-1, 1, 2)

            H, mask = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 10.0)
            if H is None:
                continue

            inliers = int(mask.sum()) if mask is not None else 0
            if inliers < min_matches:
                continue

            det = np.linalg.det(H[:2, :2])
            if det < 0.1 or det > 10.0:
                continue

            confidence = inliers / n_matches if n_matches else 0.0

            cam_center = np.float32([[cam_w / 2, cam_h / 2]]).reshape(-1, 1, 2)
            screen_pt = cv2.perspectiveTransform(cam_center, H)
            sx = float(screen_pt[0][0][0])
            sy = float(screen_pt[0][0][1])

            sx = mon["left"] + sx / feat_scale / scale
            sy = mon["top"] + sy / feat_scale / scale

            mon_w = mon["width"] / scale
            mon_h = mon["height"] / scale
            sx = max(mon["left"], min(mon["left"] + mon_w, sx))
            sy = max(mon["top"], min(mon["top"] + mon_h, sy))

            candidate = (sx, sy, inliers, confidence, idx)

            # Early exit if good enough match on preferred monitor
            if confidence >= 0.25:
                with self._lock:
                    self._last_matched_idx = idx
                return (sx, sy, inliers, confidence)

            if best is None or inliers > best[2]:
                best = candidate

        if best:
            with self._lock:
                self._last_matched_idx = best[4]
            return (best[0], best[1], best[2], best[3])

        return None


screenshot_cache = ScreenshotCache(refresh_interval=2.0)


@app.route("/locate", methods=["POST"])
def handle_locate():
    content_type = request.content_type or ""
    if "image/jpeg" not in content_type and "application/octet-stream" not in content_type:
        return jsonify({"error": "Content-Type must be image/jpeg"}), 400

    jpeg_data = request.get_data()
    if not jpeg_data or len(jpeg_data) < 100:
        return jsonify({"error": "Empty or invalid JPEG"}), 400

    t_start = time.time()
    result = screenshot_cache.locate(jpeg_data, min_matches=5)
    elapsed_ms = (time.time() - t_start) * 1000

    # Filter out low-confidence results (bad homography)
    if result and result[3] < 0.04:
        print(f"[locate] {elapsed_ms:.0f}ms x={result[0]:.0f} y={result[1]:.0f} matches={result[2]} conf={result[3]:.2f} REJECTED", flush=True)
        result = None
    elif result:
        rx, ry, mc, conf = result
        print(f"[locate] {elapsed_ms:.0f}ms x={rx:.0f} y={ry:.0f} matches={mc} conf={conf:.2f}", flush=True)
    else:
        print(f"[locate] {elapsed_ms:.0f}ms NO MATCH", flush=True)

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
    ox, oy, w, h = get_screen_size()
    print(f"[CursorServer] Virtual screen: {w}x{h} at origin ({ox}, {oy})")
    print(f"[CursorServer] Accessibility: {Quartz.CoreGraphics.CGPreflightPostEventAccess()}")
    print(f"[CursorServer] Starting on http://0.0.0.0:8765")
    app.run(host="0.0.0.0", port=8765, threaded=True)
