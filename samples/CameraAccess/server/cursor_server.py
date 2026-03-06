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
import sys
import threading
import time

ssl._create_default_https_context = ssl._create_unverified_context

import cv2
import mediapipe as mp
from mediapipe.tasks.python import BaseOptions as MPBaseOptions
from mediapipe.tasks.python.vision import (
    HandLandmarker, HandLandmarkerOptions, RunningMode as MPRunningMode,
)
import mss
import numpy as np
import Quartz
import torch
from enum import Enum
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

class GazeKalmanFilter:
    """2D Kalman filter for cursor position with velocity model.

    State: [x, y, vx, vy]
    Measurement: [x, y]

    Automatically adapts measurement noise based on match confidence.
    High confidence = trust measurement more = faster response.
    Low confidence = trust prediction more = smoother but laggier.
    """

    def __init__(self):
        # State: [x, y, vx, vy]
        self.x = np.zeros(4, dtype=np.float64)
        # State covariance
        self.P = np.eye(4, dtype=np.float64) * 1000.0
        # Process noise: position changes through velocity (low),
        # velocity can change (moderate). Tuned for ~300px raw noise.
        self.Q = np.diag([2.0, 2.0, 20.0, 20.0])
        # Base measurement noise — higher = smoother but laggier.
        # Raw variance is ~300px, so R must be well above that.
        self._base_R = 800.0
        self.initialized = False
        self._last_time = None

    def predict(self, dt=None):
        """Predict next state based on velocity model."""
        if not self.initialized:
            return
        if dt is None:
            now = time.time()
            dt = now - self._last_time if self._last_time else 0.033
            self._last_time = now
        dt = max(0.001, min(dt, 0.5))

        # State transition: x += vx*dt, y += vy*dt
        F = np.eye(4, dtype=np.float64)
        F[0, 2] = dt
        F[1, 3] = dt

        self.x = F @ self.x
        self.P = F @ self.P @ F.T + self.Q * dt

    def update(self, mx, my, confidence=0.5, match_count=20):
        """Update with a new measurement. Confidence scales noise."""
        H = np.array([[1, 0, 0, 0], [0, 1, 0, 0]], dtype=np.float64)
        z = np.array([mx, my], dtype=np.float64)

        if not self.initialized:
            self.x[:2] = z
            self.x[2:] = 0.0
            self.P = np.eye(4, dtype=np.float64) * 500.0
            self.initialized = True
            self._last_time = time.time()
            return

        # Adaptive measurement noise: low confidence = high noise = ignore
        # High confidence = low noise = trust measurement
        noise_scale = max(0.3, 1.0 - confidence) * max(1.0, 50.0 / match_count)
        R = np.eye(2, dtype=np.float64) * self._base_R * noise_scale

        # Standard Kalman update
        y_res = z - H @ self.x
        S = H @ self.P @ H.T + R
        K = self.P @ H.T @ np.linalg.inv(S)
        self.x = self.x + K @ y_res
        self.P = (np.eye(4) - K @ H) @ self.P

    def position(self, lead_time=0.0):
        """Return current estimated position, optionally projected ahead.

        lead_time: seconds to project ahead using velocity (compensates
        for network + processing latency so cursor leads the measurement).
        """
        x = float(self.x[0] + self.x[2] * lead_time)
        y = float(self.x[1] + self.x[3] * lead_time)
        return x, y

    def apply_flow(self, dx_screen, dy_screen):
        """Apply optical flow delta to position and decay velocity.

        Velocity decay prevents drift accumulation between anchor updates.
        Without decay, small systematic flow biases (JPEG artifacts, lighting)
        build up velocity that carries the cursor away.
        """
        if self.initialized:
            self.x[0] += dx_screen
            self.x[1] += dy_screen
            # Decay velocity to resist drift when no anchor corrects
            self.x[2] *= 0.85
            self.x[3] *= 0.85


_device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
_extractor = SuperPoint(max_num_keypoints=1024).eval().to(_device)
# FLANN: ~3x faster than BFMatcher for kNN (KD-tree, O(log n) vs O(n))
_flann = cv2.FlannBasedMatcher(
    {"algorithm": 1, "trees": 4},   # FLANN_INDEX_KDTREE
    {"checks": 64},
)
_MAX_CAM_DIM = 480


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
    """Decode JPEG to grayscale + color, downscale if needed.

    Returns (gray, color_rgb, h, w). color_rgb is for MediaPipe hand detection.
    """
    nparr = np.frombuffer(jpeg_bytes, np.uint8)
    color_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if color_bgr is None:
        return None, None, 0, 0
    h, w = color_bgr.shape[:2]
    max_dim = max(h, w)
    if max_dim > _MAX_CAM_DIM:
        s = _MAX_CAM_DIM / max_dim
        color_bgr = cv2.resize(color_bgr, (int(w * s), int(h * s)))
        h, w = color_bgr.shape[:2]
    gray = cv2.cvtColor(color_bgr, cv2.COLOR_BGR2GRAY)
    color_rgb = cv2.cvtColor(color_bgr, cv2.COLOR_BGR2RGB)
    return gray, color_rgb, h, w


# ---------------------------------------------------------------------------
# Hand pinch detection (MediaPipe)
# ---------------------------------------------------------------------------

class PinchState(Enum):
    OPEN = "OPEN"
    HELD = "HELD"


class PinchDetector:
    """Detect thumb-index pinch gesture from MediaPipe hand landmarks.

    Pinch = mouse_down (immediate). Release = mouse_up.
    Short pinch naturally becomes a click. Long pinch = press-and-hold.
    """

    PINCH_CLOSE = 0.045   # Normalized distance to trigger pinch
    PINCH_OPEN = 0.07     # Distance to release (hysteresis)
    DEBOUNCE_FRAMES = 2   # Consecutive frames before confirming

    def __init__(self):
        self.state = PinchState.OPEN
        self._close_count = 0
        self.distance = 1.0
        self.hand_detected = False
        self.last_action = None
        self.last_action_time = 0.0

    def update(self, thumb_tip, index_tip):
        """Update state with new landmark positions.

        Returns: ("mouse_down",) | ("mouse_up",) | None
        """
        dx = thumb_tip[0] - index_tip[0]
        dy = thumb_tip[1] - index_tip[1]
        self.distance = math.sqrt(dx * dx + dy * dy)

        if self.state == PinchState.OPEN:
            if self.distance < self.PINCH_CLOSE:
                self._close_count += 1
                if self._close_count >= self.DEBOUNCE_FRAMES:
                    self.state = PinchState.HELD
                    self.last_action = "mouse_down"
                    self.last_action_time = time.time()
                    print(f"[Hand] Pinch -> mouse_down (dist={self.distance:.3f})", flush=True)
                    return ("mouse_down",)
            else:
                self._close_count = 0

        elif self.state == PinchState.HELD:
            if self.distance > self.PINCH_OPEN:
                self.state = PinchState.OPEN
                self._close_count = 0
                self.last_action = "mouse_up"
                self.last_action_time = time.time()
                print("[Hand] Release -> mouse_up", flush=True)
                return ("mouse_up",)

        return None

    def on_hand_lost(self):
        """Call when no hand is detected - auto-release if held."""
        self.hand_detected = False
        if self.state == PinchState.HELD:
            self.state = PinchState.OPEN
            self._close_count = 0
            self.last_action = "mouse_up"
            self.last_action_time = time.time()
            print("[Hand] Hand lost -> auto mouse_up", flush=True)
            return ("mouse_up",)
        self.state = PinchState.OPEN
        self._close_count = 0
        return None


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
        [sys.executable, "-c", script],
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
        self._kalman = GazeKalmanFilter()  # Smooth + predict cursor position

        # Server-side cursor interpolation (60fps smooth movement)
        self._cursor_target = None  # Where Kalman says we should be
        self._cursor_current = None  # Where the cursor actually is (lerped)
        self._cursor_vel_hint = None  # Kalman velocity hint for spring
        self._cursor_lock = threading.Lock()
        self._cursor_thread_active = False

        # Screen content layer (per-monitor, retina-aware)
        self._screen_monitors = []  # List of (monitor, feats, retina_scale, feat_scale)
        self._screen_last_matched_idx = 0  # Prioritize last matched monitor
        self._screen_lock = threading.Lock()
        self._screen_capture_active = False

        # Hand detection (MediaPipe)
        self._hand_frame = None
        self._hand_frame_lock = threading.Lock()
        self._hand_frame_event = threading.Event()
        self._hand_enabled = True
        self._hand_thread_active = False
        self._pinch = PinchDetector()

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
            self._kalman = GazeKalmanFilter()

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
        gray, _color, h, w = decode_camera_frame(jpeg_bytes)
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
        """Locate gaze position using Kalman-filtered hybrid tracking.

        Architecture:
        - Optical flow every frame: fast delta applied to Kalman state
        - Anchor + screen matching every Nth frame: Kalman measurement update
        - Kalman filter: smooths noise, tracks velocity, adapts to confidence
        - Server moves cursor directly (no /move round-trip)

        Returns (screen_x, screen_y, match_count, confidence) or None.
        """
        if not self.is_calibrated():
            return None

        gray, color_rgb, cam_h, cam_w = decode_camera_frame(jpeg_bytes)
        if gray is None:
            return None

        # Share color frame with hand detection thread (non-blocking)
        if color_rgb is not None and self._hand_enabled:
            with self._hand_frame_lock:
                self._hand_frame = color_rgb
            self._hand_frame_event.set()

        t0 = time.time()
        self._frame_count += 1

        # Kalman predict step (advance state by dt)
        self._kalman.predict()

        # -- Optical flow: fast path every frame --
        if self._prev_gray is not None and self._kalman.initialized:
            flow_dx, flow_dy = self._compute_optical_flow(self._prev_gray, gray)
            if flow_dx != 0 or flow_dy != 0:
                # Apply flow to Kalman state, dampened to reduce drift.
                # 0.8 keeps most responsiveness while filtering accumulated noise.
                self._kalman.apply_flow(
                    -flow_dx * self._scale_factor * 0.8,
                    -flow_dy * self._scale_factor * 0.8,
                )

        # -- Anchor/screen matching: periodic absolute correction --
        need_anchor = (
            not self._kalman.initialized
            or self._frame_count >= self._anchor_interval
            or time.time() - self._last_anchor_time > 2.0
        )

        source = None
        mc, conf = 0, 0.0

        if need_anchor:
            self._frame_count = 0
            cam_feats = extract_features(gray)

            anchor_result = self._match_anchors(gray, cam_w, cam_h, cam_feats=cam_feats)
            screen_result = self._match_screen_content(cam_feats, cam_w, cam_h)

            # Prefer screen content when confident (direct pixel coords)
            best = None
            if screen_result:
                s_x, s_y, s_mc, s_conf = screen_result
                if s_mc >= 15:
                    best = screen_result
                    source = f"SCREEN scr={s_mc}"
                elif anchor_result:
                    a_x, a_y, a_mc, a_conf = anchor_result
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
                else:
                    best = screen_result
                    source = f"SCREEN scr={s_mc}"
            elif anchor_result:
                best = anchor_result
                source = "ENV"

            if best is not None:
                sx, sy, mc, conf = best

                # Outlier rejection: too few inliers → skip
                if mc < self._min_accept_matches and self._kalman.initialized:
                    self._prev_gray = gray
                    elapsed_ms = (time.time() - t0) * 1000
                    print(f"[locate] {elapsed_ms:.0f}ms {source} REJECTED "
                          f"(matches={mc} < {self._min_accept_matches})", flush=True)
                    # Still return Kalman position
                    kx, ky = self._kalman.position()
                    return (kx, ky, 0, 0.01)
                else:
                    # Kalman measurement update
                    self._kalman.update(sx, sy, confidence=conf, match_count=mc)
                    self._last_anchor_time = time.time()

        self._prev_gray = gray

        # Get smoothed position from Kalman filter
        if not self._kalman.initialized:
            elapsed_ms = (time.time() - t0) * 1000
            print(f"[locate] {elapsed_ms:.0f}ms NO MATCH", flush=True)
            return None

        # Project ahead by ~50ms to compensate for network + processing delay.
        # The frame we just processed was captured ~50ms ago, so predict where
        # the user is looking NOW, not where they were looking THEN.
        kx, ky = self._kalman.position(lead_time=0.12)

        # Clamp to screen bounds
        scr_ox, scr_oy, scr_w, scr_h = get_screen_size()
        kx = max(scr_ox, min(scr_ox + scr_w, kx))
        ky = max(scr_oy, min(scr_oy + scr_h, ky))
        self._current_pos = (kx, ky)

        # Set target for 60fps interpolation thread (smooth movement)
        # Pass Kalman velocity so spring can start moving immediately
        kvx = float(self._kalman.x[2])
        kvy = float(self._kalman.x[3])
        self.set_cursor_target(kx, ky, vel_x=kvx, vel_y=kvy)

        elapsed_ms = (time.time() - t0) * 1000
        if source:
            print(f"[locate] {elapsed_ms:.0f}ms {source} x={kx:.0f} y={ky:.0f} "
                  f"matches={mc} conf={conf:.2f}", flush=True)

        return (kx, ky, mc, conf)

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

            raw = _flann.knnMatch(cam_desc, anc_desc, k=2)
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
        best_scale = top[0][4]  # sqrt(det) from best anchor

        # Full camera-to-screen scale for optical flow.
        # Anchor matching uses: cam_to_screen = scr_dim / frame_dim * sqrt(det)
        # Previously _scale_factor was just sqrt(det) (~1.0), missing the
        # scr/frame ratio (~4x). This made subtle head movements invisible.
        scr_ox2, scr_oy2, scr_w2, scr_h2 = get_screen_size()
        new_sf = (scr_w2 / cam_w + scr_h2 / cam_h) / 2.0 * best_scale
        if abs(new_sf - self._scale_factor) > 0.5:
            print(f"[scale] camera->screen factor: {new_sf:.2f} "
                  f"(was {self._scale_factor:.2f}, sqrt_det={best_scale:.2f})", flush=True)
        self._scale_factor = new_sf
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

        # Dead zone: filter camera sensor + JPEG noise but allow real movements
        mag = math.sqrt(dx * dx + dy * dy)
        if mag < 1.5:
            return 0.0, 0.0

        return dx, dy

    # -- Server-side cursor interpolation --

    def start_cursor_interpolation(self):
        """Start 60fps thread that smoothly lerps cursor toward Kalman target."""
        if self._cursor_thread_active:
            return
        self._cursor_thread_active = True
        t = threading.Thread(target=self._cursor_interpolation_loop, daemon=True)
        t.start()
        print("[Cursor] 60fps interpolation started", flush=True)

    def _cursor_interpolation_loop(self):
        """60fps: critically damped spring for smooth cursor movement.

        Instead of lerp (which causes velocity pulses on each Kalman update),
        this uses a spring-damper that smoothly accelerates and decelerates.
        Velocity changes are gradual, eliminating the periodic 'pulse' feeling.
        """
        interval = 1.0 / 60.0
        vx, vy = 0.0, 0.0
        # Spring parameters: omega = natural frequency, zeta = 1.0 = critical damping
        omega = 11.0  # Higher = faster response (but >12 can feel twitchy)

        while self._cursor_thread_active:
            with self._cursor_lock:
                target = self._cursor_target
                current = self._cursor_current
                vel_hint = getattr(self, '_cursor_vel_hint', None)
                if vel_hint is not None:
                    self._cursor_vel_hint = None

            # Apply Kalman velocity hint to spring (reduces lag on direction changes)
            if vel_hint is not None:
                hvx, hvy = vel_hint
                # Blend: 50% spring velocity + 50% Kalman velocity
                vx = vx * 0.5 + hvx * 0.5
                vy = vy * 0.5 + hvy * 0.5

            if target is not None and current is not None:
                tx, ty = target
                cx, cy = current
                dx = tx - cx
                dy = ty - cy
                dist = math.sqrt(dx * dx + dy * dy)

                if dist > 1.0:
                    # Critically damped spring: zeta = 1.0
                    # acceleration = omega^2 * (target - pos) - 2 * omega * velocity
                    dt = interval
                    ax = omega * omega * dx - 2.0 * omega * vx
                    ay = omega * omega * dy - 2.0 * omega * vy
                    vx += ax * dt
                    vy += ay * dt
                    nx = cx + vx * dt
                    ny = cy + vy * dt
                    if self._pinch.state == PinchState.HELD:
                        mouse_drag_to(nx, ny)
                    else:
                        move_mouse(nx, ny)
                    with self._cursor_lock:
                        self._cursor_current = (nx, ny)
                else:
                    # Close enough — damp velocity to zero
                    vx *= 0.8
                    vy *= 0.8

            time.sleep(interval)

    def set_cursor_target(self, x, y, vel_x=None, vel_y=None):
        """Set the target position for the interpolation thread.

        vel_x/vel_y: optional Kalman velocity hint (px/s) so the spring
        can start moving in the right direction immediately.
        """
        with self._cursor_lock:
            self._cursor_target = (x, y)
            if vel_x is not None and vel_y is not None:
                self._cursor_vel_hint = (vel_x, vel_y)
            # First point: jump directly
            if self._cursor_current is None:
                self._cursor_current = (x, y)
                move_mouse(x, y)

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
        _MAX_SCREEN_DIM = 1024
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

    # -- Hand detection (MediaPipe) --

    def start_hand_detection(self):
        """Start background thread for MediaPipe hand detection."""
        if self._hand_thread_active:
            return
        self._hand_thread_active = True
        t = threading.Thread(target=self._hand_detection_loop, daemon=True)
        t.start()
        print("[Hand] Detection started (MediaPipe Hands)", flush=True)

    def _hand_detection_loop(self):
        """Background: detect hands and process pinch gestures."""
        model_path = os.path.join(os.path.dirname(__file__), "hand_landmarker.task")
        if not os.path.exists(model_path):
            print("[Hand] hand_landmarker.task not found - hand detection disabled", flush=True)
            return

        options = HandLandmarkerOptions(
            base_options=MPBaseOptions(model_asset_path=model_path),
            running_mode=MPRunningMode.IMAGE,
            num_hands=1,
            min_hand_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        landmarker = HandLandmarker.create_from_options(options)
        no_hand_count = 0

        while self._hand_thread_active:
            # Wait for a new frame (timeout 1s to allow clean shutdown)
            if not self._hand_frame_event.wait(timeout=1.0):
                continue
            self._hand_frame_event.clear()

            if not self._hand_enabled:
                continue

            with self._hand_frame_lock:
                frame = self._hand_frame
                self._hand_frame = None

            if frame is None:
                continue

            # Convert numpy RGB to MediaPipe Image
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame)
            results = landmarker.detect(mp_image)

            if results.hand_landmarks:
                no_hand_count = 0
                self._pinch.hand_detected = True
                hand = results.hand_landmarks[0]
                thumb_tip = hand[4]   # Landmark 4: thumb tip
                index_tip = hand[8]   # Landmark 8: index finger tip

                action = self._pinch.update(
                    (thumb_tip.x, thumb_tip.y),
                    (index_tip.x, index_tip.y),
                )

                if action is not None:
                    self._execute_pinch_action(action)
            else:
                no_hand_count += 1
                # Only trigger hand-lost after a few frames to avoid false negatives
                if no_hand_count > 3:
                    action = self._pinch.on_hand_lost()
                    if action is not None:
                        self._execute_pinch_action(action)

        landmarker.close()

    def _execute_pinch_action(self, action):
        """Execute a pinch action at the current Kalman cursor position."""
        if not self._kalman.initialized:
            return
        x, y = self._kalman.position()
        action_type = action[0]
        if action_type == "mouse_down":
            mouse_down(x, y)
        elif action_type == "mouse_up":
            mouse_up(x, y)

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

            raw = _flann.knnMatch(cam_desc, scr_desc, k=2)
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
        "hand": gaze_tracker._pinch.state.value,
    })


# ---------------------------------------------------------------------------
# Hand tracking endpoints
# ---------------------------------------------------------------------------

@app.route("/hand_status", methods=["GET"])
def handle_hand_status():
    p = gaze_tracker._pinch
    return jsonify({
        "hand_detected": p.hand_detected,
        "pinch_state": p.state.value,
        "pinch_distance": round(p.distance, 4),
        "last_action": p.last_action,
        "last_action_time": p.last_action_time,
        "enabled": gaze_tracker._hand_enabled,
    })


@app.route("/hand_tracking", methods=["POST"])
def handle_hand_tracking():
    data = request.json
    enabled = data.get("enabled", True)
    gaze_tracker._hand_enabled = bool(enabled)
    print(f"[Hand] Tracking {'enabled' if enabled else 'disabled'}", flush=True)
    return jsonify({"status": "ok", "enabled": gaze_tracker._hand_enabled})


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
    gaze_tracker.start_cursor_interpolation()
    gaze_tracker.start_hand_detection()
    print(f"[CursorServer] Starting on http://0.0.0.0:8765")
    app.run(host="0.0.0.0", port=8765, threaded=True)
