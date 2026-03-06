#!/usr/bin/env python3
"""
macOS Cursor Control HTTP Server - Hybrid Gaze Tracking.

Uses three layers for gaze-to-cursor mapping:
1. Environment anchors (calibrated): stable room features (desk, walls, bezels)
2. Screen content (live): periodic screenshots matched against camera frames
3. Optical flow: smooth inter-frame tracking between anchor/screen matches

Environment anchors provide stable baseline. Screen content adds pixel-precise
refinement when visible. Both are fused by inlier-weighted averaging.

Requires Accessibility permission for Terminal.

Usage:
  pip install flask pyobjc-framework-Quartz pyobjc-framework-Cocoa \
      opencv-python-headless mss numpy torch lightglue
  python cursor_server.py

Endpoints:
  POST /move     {"x": float, "y": float}
  POST /click    {"x": float, "y": float}
  POST /drag     {"from_x", "from_y", "to_x", "to_y", "steps", "duration"}
  POST /locate   (JPEG body) -> {"status", "x", "y", "matches", "confidence"}
  GET  /position  -> {"x": float, "y": float}
  GET  /screen    -> {"width": int, "height": int}
  GET  /health    -> {"status": "ok"}
  POST /calibrate/start   -> starts calibration sequence
  POST /calibrate/capture (JPEG body) -> captures anchor at current dot
  POST /calibrate/finish  -> ends calibration, switches to anchored tracking
  GET  /calibrate/status  -> {"calibrated": bool, "anchors": int, ...}
"""

import json
import math
import os
import ssl
import subprocess
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

# ---------------------------------------------------------------------------
# Screen utilities
# ---------------------------------------------------------------------------

def get_screen_size():
    max_displays = 16
    (err, display_ids, count) = Quartz.CGGetActiveDisplayList(max_displays, None, None)
    if err != 0 or count == 0:
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


def get_primary_screen_logical():
    """Return (width, height) of the primary display in logical points."""
    did = Quartz.CGMainDisplayID()
    return (Quartz.CGDisplayPixelsWide(did), Quartz.CGDisplayPixelsHigh(did))


# ---------------------------------------------------------------------------
# Cursor control
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Flask cursor endpoints
# ---------------------------------------------------------------------------

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
    return jsonify({"status": "ok", "accessibility": trusted,
                    "calibrated": gaze_tracker.is_calibrated()})


# ---------------------------------------------------------------------------
# SuperPoint feature extractor (shared)
# ---------------------------------------------------------------------------

_device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
_extractor = SuperPoint(max_num_keypoints=2048).eval().to(_device)
_bf = cv2.BFMatcher(cv2.NORM_L2)
_MAX_CAM_DIM = 640


def extract_features(gray_img):
    """Extract SuperPoint keypoints and descriptors from a grayscale image."""
    tensor = numpy_image_to_torch(gray_img).to(_device)
    with torch.no_grad():
        feats = _extractor.extract(tensor)
    return {
        "keypoints": feats["keypoints"][0].cpu().numpy(),
        "descriptors": feats["descriptors"][0].cpu().numpy(),
    }


def decode_camera_frame(jpeg_bytes):
    """Decode JPEG to grayscale, downscale if needed. Returns (gray, h, w)."""
    nparr = np.frombuffer(jpeg_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None, 0, 0
    h, w = img.shape[:2]
    max_dim = max(h, w)
    if max_dim > _MAX_CAM_DIM:
        s = _MAX_CAM_DIM / max_dim
        img = cv2.resize(img, (int(w * s), int(h * s)))
        h, w = img.shape[:2]
    return img, h, w


# ---------------------------------------------------------------------------
# Calibration dot overlay (uses osascript for simplicity)
# ---------------------------------------------------------------------------

_dot_process = None


def show_calibration_dot(screen_x, screen_y, dot_size=30):
    """Show a red dot at the given screen position using a Python overlay."""
    global _dot_process
    hide_calibration_dot()

    script = f'''
import Cocoa
import Quartz

class DotView(Cocoa.NSView):
    def drawRect_(self, rect):
        Cocoa.NSColor.redColor().setFill()
        path = Cocoa.NSBezierPath.bezierPathWithOvalInRect_(
            Cocoa.NSMakeRect(0, 0, {dot_size}, {dot_size})
        )
        path.fill()

app = Cocoa.NSApplication.sharedApplication()
screen_h = Quartz.CGDisplayPixelsHigh(Quartz.CGMainDisplayID())
# Flip Y for Cocoa coordinates (origin bottom-left)
cocoa_y = screen_h - {screen_y} - {dot_size} // 2
win = Cocoa.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
    Cocoa.NSMakeRect({screen_x} - {dot_size}//2, cocoa_y, {dot_size}, {dot_size}),
    Cocoa.NSWindowStyleMaskBorderless,
    Cocoa.NSBackingStoreBuffered,
    False,
)
win.setLevel_(Cocoa.NSStatusWindowLevel + 1)
win.setOpaque_(False)
win.setBackgroundColor_(Cocoa.NSColor.clearColor())
win.setIgnoresMouseEvents_(True)
view = DotView.alloc().initWithFrame_(Cocoa.NSMakeRect(0, 0, {dot_size}, {dot_size}))
win.setContentView_(view)
win.makeKeyAndOrderFront_(None)
app.run()
'''
    _dot_process = subprocess.Popen(
        ["python3", "-c", script],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def hide_calibration_dot():
    """Kill the dot overlay process."""
    global _dot_process
    if _dot_process is not None:
        _dot_process.terminate()
        _dot_process = None


def _kill_all_dot_processes():
    """Kill any lingering DotView overlay processes."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "DotView"],
            capture_output=True, text=True, timeout=2,
        )
        for pid in result.stdout.strip().split("\n"):
            if pid:
                subprocess.run(["kill", pid], timeout=2)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Environment-Anchored Gaze Tracker
# ---------------------------------------------------------------------------

class GazeTracker:
    """Tracks gaze using environment features captured during calibration.

    Calibration: user looks at known screen points while wearing glasses.
    We capture room features (desk, walls, bezels) at each pose.

    Runtime: match current camera frame against all anchors. Use homography
    to compute offset from nearest anchor's pose. Optical flow provides
    smooth inter-frame tracking.
    """

    # Per-display offsets: 3 dots per display (top-left area, center, bottom-right area)
    _PER_DISPLAY_OFFSETS = [
        (0.2, 0.2),   # top-left area
        (0.5, 0.5),   # center
        (0.8, 0.8),   # bottom-right area
    ]

    def __init__(self):
        self._lock = threading.Lock()
        # Calibration anchors: list of {screen_x, screen_y, keypoints, descriptors}
        self._anchors = []
        self._calibrating = False
        self._cal_index = 0  # Current calibration point index
        self._cal_points = []  # List of (abs_x, abs_y) for calibration dots

        # Runtime state
        self._prev_gray = None  # Previous camera frame for optical flow
        self._current_pos = None  # Current estimated screen position (x, y)
        self._scale_factor = 1.0  # Camera pixels -> screen pixels
        self._last_anchor_time = 0
        self._frame_count = 0  # Frames since last anchor match
        self._anchor_interval = 5  # Do anchor matching every N frames
        self._min_accept_matches = 12  # Minimum inliers to accept an anchor result
        self._ema_alpha = 0.35  # EMA blend: 0=ignore new, 1=no smoothing

        # Screen content layer (per-monitor, retina-aware)
        self._screen_monitors = []  # List of (monitor, feats, retina_scale, feat_scale)
        self._screen_last_matched_idx = 0  # Prioritize last matched monitor
        self._screen_lock = threading.Lock()
        self._screen_capture_active = False

        # Load saved calibration if exists
        self._load_calibration()

    def is_calibrated(self):
        return len(self._anchors) >= 4

    @staticmethod
    def _generate_calibration_points():
        """Generate calibration dot positions: 3 per physical display."""
        max_displays = 16
        (err, display_ids, count) = Quartz.CGGetActiveDisplayList(max_displays, None, None)
        if err != 0 or count == 0:
            # Fallback to primary
            did = Quartz.CGMainDisplayID()
            w = Quartz.CGDisplayPixelsWide(did)
            h = Quartz.CGDisplayPixelsHigh(did)
            return [(int(w * 0.5), int(h * 0.5))]

        points = []
        for did in display_ids[:count]:
            bounds = Quartz.CGDisplayBounds(did)
            dx, dy = bounds.origin.x, bounds.origin.y
            dw, dh = bounds.size.width, bounds.size.height
            for (nx, ny) in GazeTracker._PER_DISPLAY_OFFSETS:
                px = int(dx + nx * dw)
                py = int(dy + ny * dh)
                points.append((px, py))
        return points

    # -- Calibration --

    def start_calibration(self):
        """Begin calibration sequence. Returns the first dot position."""
        cal_points = self._generate_calibration_points()
        with self._lock:
            self._anchors = []
            self._calibrating = True
            self._cal_index = 0
            self._cal_points = cal_points
            self._prev_gray = None
            self._current_pos = None

        # Show first dot
        sx, sy = cal_points[0]
        show_calibration_dot(sx, sy)
        print(f"[Calibrate] Started. {len(cal_points)} points across "
              f"{len(cal_points) // 3} displays. Point 0: ({sx}, {sy})", flush=True)
        return {
            "point_index": 0,
            "total_points": len(cal_points),
            "screen_x": sx,
            "screen_y": sy,
        }

    def capture_anchor(self, jpeg_bytes):
        """Capture room features at the current calibration dot position."""
        if not self._calibrating:
            return {"error": "Not calibrating"}

        idx = self._cal_index
        if idx >= len(self._cal_points):
            return {"error": "All points captured"}

        # Decode and extract features
        gray, h, w = decode_camera_frame(jpeg_bytes)
        if gray is None:
            return {"error": "Bad JPEG"}

        feats = extract_features(gray)

        # Store anchor (absolute screen coordinates)
        sx, sy = self._cal_points[idx]

        anchor = {
            "screen_x": float(sx),
            "screen_y": float(sy),
            "keypoints": feats["keypoints"],
            "descriptors": feats["descriptors"],
            "frame_w": w,
            "frame_h": h,
        }

        with self._lock:
            self._anchors.append(anchor)
            self._cal_index = idx + 1

        n_kp = len(feats["keypoints"])
        print(f"[Calibrate] Captured point {idx}: ({sx}, {sy}) "
              f"with {n_kp} room features", flush=True)

        # Show next dot or finish
        next_idx = idx + 1
        if next_idx < len(self._cal_points):
            sx2, sy2 = self._cal_points[next_idx]
            show_calibration_dot(sx2, sy2)
            return {
                "status": "captured",
                "point_index": next_idx,
                "total_points": len(self._cal_points),
                "screen_x": sx2,
                "screen_y": sy2,
                "features": n_kp,
            }
        else:
            return {
                "status": "all_captured",
                "total_points": len(self._cal_points),
                "features": n_kp,
            }

    def finish_calibration(self):
        """End calibration mode, save anchors, switch to tracking."""
        hide_calibration_dot()
        # Kill any other lingering dot processes
        _kill_all_dot_processes()
        with self._lock:
            self._calibrating = False
        self._save_calibration()
        n = len(self._anchors)
        print(f"[Calibrate] Finished with {n} anchors", flush=True)
        return {"status": "ok", "anchors": n}

    # -- Runtime tracking --

    def locate(self, jpeg_bytes):
        """Locate gaze position using environment anchors + optical flow.

        Strategy: optical flow every frame (~5ms), anchor matching every
        N frames (~160ms) for absolute correction. This keeps latency low
        while preventing drift.

        Returns (screen_x, screen_y, match_count, confidence) or None.
        """
        if not self.is_calibrated():
            return None

        gray, cam_h, cam_w = decode_camera_frame(jpeg_bytes)
        if gray is None:
            return None

        t0 = time.time()
        self._frame_count += 1

        # -- Optical flow: fast path every frame --
        flow_dx, flow_dy = 0.0, 0.0
        if self._prev_gray is not None and self._current_pos is not None:
            flow_dx, flow_dy = self._compute_optical_flow(self._prev_gray, gray)

        # Apply flow immediately if we have a position
        flow_applied = False
        if self._current_pos is not None and (flow_dx != 0 or flow_dy != 0):
            ox, oy = self._current_pos
            nx = ox - flow_dx * self._scale_factor
            ny = oy - flow_dy * self._scale_factor
            scr_ox, scr_oy, scr_w, scr_h = get_screen_size()
            nx = max(scr_ox, min(scr_ox + scr_w, nx))
            ny = max(scr_oy, min(scr_oy + scr_h, ny))
            self._current_pos = (nx, ny)
            flow_applied = True

        # -- Hybrid matching: periodic absolute correction --
        need_anchor = (
            self._current_pos is None  # No position yet
            or self._frame_count >= self._anchor_interval  # Time for correction
            or time.time() - self._last_anchor_time > 2.0  # Stale position
        )

        if need_anchor:
            self._frame_count = 0
            # Extract features once, reuse for both matchers
            cam_feats = extract_features(gray)

            anchor_result = self._match_anchors(gray, cam_w, cam_h, cam_feats=cam_feats)
            screen_result = self._match_screen_content(cam_feats, cam_w, cam_h)

            # Fuse results: screen content is 3x more trusted (direct pixel coords)
            best = None
            source = None
            if anchor_result and screen_result:
                a_x, a_y, a_mc, a_conf = anchor_result
                s_x, s_y, s_mc, s_conf = screen_result
                # Screen content gives direct pixel coordinates — weight 3x
                w_a = a_mc
                w_s = s_mc * 3.0
                total = w_a + w_s
                w_a /= total
                w_s /= total
                best = (
                    a_x * w_a + s_x * w_s,
                    a_y * w_a + s_y * w_s,
                    a_mc + s_mc,
                    a_conf * w_a + s_conf * w_s,
                )
                source = f"HYBRID env={a_mc} scr={s_mc}"
            elif anchor_result:
                best = anchor_result
                source = "ENV"
            elif screen_result:
                best = screen_result
                source = "SCREEN"

            if best is not None:
                sx, sy, mc, conf = best

                # Outlier rejection: too few inliers → skip
                if mc < self._min_accept_matches and self._current_pos is not None:
                    self._prev_gray = gray
                    elapsed_ms = (time.time() - t0) * 1000
                    print(f"[locate] {elapsed_ms:.0f}ms {source} REJECTED "
                          f"(matches={mc} < {self._min_accept_matches})", flush=True)
                else:
                    # EMA smoothing: blend new result with current position
                    if self._current_pos is not None:
                        ox, oy = self._current_pos
                        # Higher alpha for high-confidence results
                        alpha = self._ema_alpha
                        if conf > 0.6:
                            alpha = min(0.6, alpha * 1.5)
                        sx = ox + (sx - ox) * alpha
                        sy = oy + (sy - oy) * alpha

                    self._current_pos = (sx, sy)
                    self._last_anchor_time = time.time()
                    self._prev_gray = gray
                    elapsed_ms = (time.time() - t0) * 1000
                    print(f"[locate] {elapsed_ms:.0f}ms {source} x={sx:.0f} y={sy:.0f} "
                          f"matches={mc} conf={conf:.2f}", flush=True)
                    return (sx, sy, mc, conf)

        self._prev_gray = gray
        elapsed_ms = (time.time() - t0) * 1000

        # Return flow-updated position
        if self._current_pos is not None:
            nx, ny = self._current_pos
            if flow_applied:
                age = time.time() - self._last_anchor_time
                if elapsed_ms > 20:  # Only log slow frames
                    print(f"[locate] {elapsed_ms:.0f}ms FLOW x={nx:.0f} y={ny:.0f} "
                          f"age={age:.1f}s", flush=True)
                return (nx, ny, 0, 0.01)
            else:
                # No flow movement, return current position
                return (nx, ny, 0, 0.01)

        print(f"[locate] {elapsed_ms:.0f}ms NO MATCH", flush=True)
        return None

    def _match_anchors(self, cam_gray, cam_w, cam_h, cam_feats=None, min_matches=5):
        """Match camera frame against calibration anchors.

        Returns (screen_x, screen_y, match_count, confidence) or None.
        """
        if cam_feats is None:
            cam_feats = extract_features(cam_gray)
        cam_desc = cam_feats["descriptors"]
        cam_kps = cam_feats["keypoints"]

        if len(cam_desc) < 2:
            return None

        with self._lock:
            anchors = list(self._anchors)

        candidates = []  # List of (sx, sy, inliers, confidence, pixel_scale)

        for anchor in anchors:
            anc_desc = anchor["descriptors"]
            anc_kps = anchor["keypoints"]

            if len(anc_desc) < 2:
                continue

            raw = _bf.knnMatch(cam_desc, anc_desc, k=2)
            matches = []
            for pair in raw:
                if len(pair) == 2:
                    m, n = pair
                    if m.distance < 0.75 * n.distance:
                        matches.append(m)

            n_matches = len(matches)
            if n_matches < min_matches:
                continue

            src_pts = cam_kps[[m.queryIdx for m in matches]].reshape(-1, 1, 2)
            dst_pts = anc_kps[[m.trainIdx for m in matches]].reshape(-1, 1, 2)

            H, mask = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 10.0)
            if H is None:
                continue

            inliers = int(mask.sum()) if mask is not None else 0
            if inliers < min_matches:
                continue

            det = np.linalg.det(H[:2, :2])
            if det < 0.01 or det > 100.0:
                continue

            confidence = inliers / n_matches if n_matches else 0.0

            # Project camera center through homography to anchor space
            cam_center = np.float32([[cam_w / 2, cam_h / 2]]).reshape(-1, 1, 2)
            anc_pt = cv2.perspectiveTransform(cam_center, H)
            ax = float(anc_pt[0][0][0])
            ay = float(anc_pt[0][0][1])

            anc_cx = anchor["frame_w"] / 2
            anc_cy = anchor["frame_h"] / 2
            offset_x = ax - anc_cx
            offset_y = ay - anc_cy

            pixel_scale = np.sqrt(abs(det))

            scr_ox, scr_oy, scr_w, scr_h = get_screen_size()
            cam_to_screen_x = scr_w / anchor["frame_w"] * pixel_scale
            cam_to_screen_y = scr_h / anchor["frame_h"] * pixel_scale

            sx = anchor["screen_x"] + offset_x * cam_to_screen_x
            sy = anchor["screen_y"] + offset_y * cam_to_screen_y

            # Clamp
            sx = max(scr_ox, min(scr_ox + scr_w, sx))
            sy = max(scr_oy, min(scr_oy + scr_h, sy))

            candidates.append((sx, sy, inliers, confidence, pixel_scale))

        if not candidates:
            return None

        # Top-N weighted average: use top 3 anchors by inlier count
        candidates.sort(key=lambda c: c[2], reverse=True)
        top = candidates[:3]

        total_inliers = sum(c[2] for c in top)
        avg_x = sum(c[0] * c[2] for c in top) / total_inliers
        avg_y = sum(c[1] * c[2] for c in top) / total_inliers
        avg_conf = sum(c[3] * c[2] for c in top) / total_inliers
        best_scale = top[0][4]

        self._scale_factor = best_scale
        return (avg_x, avg_y, total_inliers, avg_conf)

    def _compute_optical_flow(self, prev_gray, curr_gray):
        """Compute dominant motion between frames using sparse optical flow.

        Returns (dx, dy) in camera pixels — how much the view shifted.
        """
        # Detect good features in previous frame
        prev_pts = cv2.goodFeaturesToTrack(
            prev_gray, maxCorners=200, qualityLevel=0.01,
            minDistance=10, blockSize=7
        )
        if prev_pts is None or len(prev_pts) < 10:
            return 0.0, 0.0

        # Track them in current frame
        curr_pts, status, _ = cv2.calcOpticalFlowPyrLK(
            prev_gray, curr_gray, prev_pts, None,
            winSize=(21, 21), maxLevel=3,
            criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01),
        )

        if curr_pts is None:
            return 0.0, 0.0

        # Filter good tracks
        good_mask = status.ravel() == 1
        if good_mask.sum() < 5:
            return 0.0, 0.0

        p0 = prev_pts[good_mask].reshape(-1, 2)
        p1 = curr_pts[good_mask].reshape(-1, 2)

        # Compute per-point displacement
        displacements = p1 - p0

        # Use median for robustness (rejects outliers from moving objects)
        dx = float(np.median(displacements[:, 0]))
        dy = float(np.median(displacements[:, 1]))

        return dx, dy

    # -- Persistence --

    def _save_calibration(self):
        """Save calibration anchors to disk."""
        save_path = os.path.join(os.path.dirname(__file__), "calibration.json")
        data = []
        for a in self._anchors:
            data.append({
                "screen_x": a["screen_x"],
                "screen_y": a["screen_y"],
                "frame_w": a["frame_w"],
                "frame_h": a["frame_h"],
                "keypoints": a["keypoints"].tolist(),
                "descriptors": a["descriptors"].tolist(),
            })
        with open(save_path, "w") as f:
            json.dump(data, f)
        print(f"[Calibrate] Saved {len(data)} anchors to {save_path}", flush=True)

    def _load_calibration(self):
        """Load calibration anchors from disk if available."""
        save_path = os.path.join(os.path.dirname(__file__), "calibration.json")
        if not os.path.exists(save_path):
            return
        try:
            with open(save_path, "r") as f:
                data = json.load(f)
            self._anchors = []
            for d in data:
                self._anchors.append({
                    "screen_x": d["screen_x"],
                    "screen_y": d["screen_y"],
                    "frame_w": d["frame_w"],
                    "frame_h": d["frame_h"],
                    "keypoints": np.array(d["keypoints"], dtype=np.float32),
                    "descriptors": np.array(d["descriptors"], dtype=np.float32),
                })
            print(f"[Calibrate] Loaded {len(self._anchors)} anchors from disk", flush=True)
        except Exception as e:
            print(f"[Calibrate] Failed to load calibration: {e}", flush=True)

    # -- Screen content capture (hybrid layer) --

    def start_screen_capture(self):
        """Start background thread to periodically capture screen content."""
        if self._screen_capture_active:
            return
        self._screen_capture_active = True
        t = threading.Thread(target=self._screen_capture_loop, daemon=True)
        t.start()
        print("[ScreenContent] Background capture started (every 3s)", flush=True)

    def _screen_capture_loop(self):
        """Background: capture per-monitor screenshots + extract features."""
        _MAX_SCREEN_DIM = 1600
        while self._screen_capture_active:
            try:
                monitors = []
                logical_w = Quartz.CGDisplayPixelsWide(Quartz.CGMainDisplayID())

                with mss.mss() as sct:
                    primary_w = sct.monitors[1]["width"] if len(sct.monitors) > 1 else 1
                    retina_scale = primary_w / logical_w if logical_w > 0 else 1.0

                    for mon in sct.monitors[1:]:  # Skip virtual screen [0]
                        screenshot = sct.grab(mon)
                        img = np.array(screenshot)[:, :, :3]
                        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
                        sh, sw = gray.shape[:2]
                        feat_scale = 1.0
                        max_dim = max(sh, sw)
                        if max_dim > _MAX_SCREEN_DIM:
                            feat_scale = _MAX_SCREEN_DIM / max_dim
                            gray = cv2.resize(gray, (int(sw * feat_scale), int(sh * feat_scale)))
                        feats = extract_features(gray)
                        monitors.append((mon, feats, retina_scale, feat_scale))

                with self._screen_lock:
                    self._screen_monitors = monitors

            except Exception as e:
                print(f"[ScreenContent] Capture error: {e}", flush=True)

            time.sleep(2.0)

    def _match_screen_content(self, cam_feats, cam_w, cam_h, min_matches=7):
        """Match camera frame against per-monitor screenshots.

        Uses retina scaling and per-monitor feature extraction from the
        old ScreenshotCache approach for better accuracy.

        Returns (screen_x, screen_y, match_count, confidence) or None.
        """
        with self._screen_lock:
            if not self._screen_monitors:
                return None
            monitors = list(self._screen_monitors)
            start_idx = self._screen_last_matched_idx

        cam_desc = cam_feats["descriptors"]
        cam_kps = cam_feats["keypoints"]

        if len(cam_desc) < 2:
            return None

        # Try last matched monitor first for faster convergence
        order = [start_idx] + [i for i in range(len(monitors)) if i != start_idx]
        if start_idx >= len(monitors):
            order = list(range(len(monitors)))

        best = None  # (sx, sy, inliers, confidence, idx)

        for idx in order:
            mon, screen_feats, retina_scale, feat_scale = monitors[idx]

            scr_desc = screen_feats["descriptors"]
            scr_kps = screen_feats["keypoints"]

            if len(scr_desc) < 2:
                continue

            raw = _bf.knnMatch(cam_desc, scr_desc, k=2)
            matches = []
            for pair in raw:
                if len(pair) == 2:
                    m, n = pair
                    if m.distance < 0.85 * n.distance:
                        matches.append(m)

            if len(matches) < min_matches:
                continue

            src_pts = cam_kps[[m.queryIdx for m in matches]].reshape(-1, 1, 2)
            dst_pts = scr_kps[[m.trainIdx for m in matches]].reshape(-1, 1, 2)

            H, mask = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 5.0)
            if H is None:
                continue

            inliers = int(mask.sum()) if mask is not None else 0
            if inliers < min_matches:
                continue

            det = np.linalg.det(H[:2, :2])
            if det < 0.1 or det > 10.0:
                continue

            confidence = inliers / len(matches) if matches else 0.0

            # Median of inlier screen points — more robust than
            # projecting camera center, especially at distance
            inlier_mask = mask.ravel().astype(bool)
            inlier_dst = dst_pts[inlier_mask].reshape(-1, 2)
            sx = float(np.median(inlier_dst[:, 0]))
            sy = float(np.median(inlier_dst[:, 1]))

            # Scale back: feature space -> retina pixels -> logical points
            sx = mon["left"] + sx / feat_scale / retina_scale
            sy = mon["top"] + sy / feat_scale / retina_scale

            # Clamp to this monitor's logical bounds
            mon_w = mon["width"] / retina_scale
            mon_h = mon["height"] / retina_scale
            mon_left = mon["left"] / retina_scale if retina_scale > 1 else mon["left"]
            mon_top = mon["top"] / retina_scale if retina_scale > 1 else mon["top"]
            sx = max(mon_left, min(mon_left + mon_w, sx))
            sy = max(mon_top, min(mon_top + mon_h, sy))

            # Early exit if confident match on preferred monitor
            if confidence >= 0.25:
                with self._screen_lock:
                    self._screen_last_matched_idx = idx
                return (sx, sy, inliers, confidence)

            candidate = (sx, sy, inliers, confidence, idx)
            if best is None or inliers > best[2]:
                best = candidate

        if best:
            with self._screen_lock:
                self._screen_last_matched_idx = best[4]
            return (best[0], best[1], best[2], best[3])

        return None


# ---------------------------------------------------------------------------
# Global tracker instance
# ---------------------------------------------------------------------------

gaze_tracker = GazeTracker()


# ---------------------------------------------------------------------------
# Calibration endpoints
# ---------------------------------------------------------------------------

@app.route("/calibrate/start", methods=["POST"])
def handle_calibrate_start():
    result = gaze_tracker.start_calibration()
    return jsonify(result)


@app.route("/calibrate/capture", methods=["POST"])
def handle_calibrate_capture():
    jpeg_data = request.get_data()
    if not jpeg_data or len(jpeg_data) < 100:
        return jsonify({"error": "Empty or invalid JPEG"}), 400
    result = gaze_tracker.capture_anchor(jpeg_data)
    return jsonify(result)


@app.route("/calibrate/finish", methods=["POST"])
def handle_calibrate_finish():
    result = gaze_tracker.finish_calibration()
    return jsonify(result)


@app.route("/calibrate/status", methods=["GET"])
def handle_calibrate_status():
    return jsonify({
        "calibrated": gaze_tracker.is_calibrated(),
        "anchors": len(gaze_tracker._anchors),
        "calibrating": gaze_tracker._calibrating,
        "cal_index": gaze_tracker._cal_index,
    })


# ---------------------------------------------------------------------------
# Locate endpoint (uses environment-anchored tracking)
# ---------------------------------------------------------------------------

@app.route("/locate", methods=["POST"])
def handle_locate():
    content_type = request.content_type or ""
    if "image/jpeg" not in content_type and "application/octet-stream" not in content_type:
        return jsonify({"error": "Content-Type must be image/jpeg"}), 400

    jpeg_data = request.get_data()
    if not jpeg_data or len(jpeg_data) < 100:
        return jsonify({"error": "Empty or invalid JPEG"}), 400

    t_start = time.time()
    result = gaze_tracker.locate(jpeg_data)
    elapsed_ms = (time.time() - t_start) * 1000

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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    ox, oy, w, h = get_screen_size()
    print(f"[CursorServer] Virtual screen: {w}x{h} at origin ({ox}, {oy})")
    print(f"[CursorServer] Accessibility: {Quartz.CoreGraphics.CGPreflightPostEventAccess()}")
    print(f"[CursorServer] Calibrated: {gaze_tracker.is_calibrated()} "
          f"({len(gaze_tracker._anchors)} anchors)")
    gaze_tracker.start_screen_capture()
    print(f"[CursorServer] Starting on http://0.0.0.0:8765")
    app.run(host="0.0.0.0", port=8765, threaded=True)
