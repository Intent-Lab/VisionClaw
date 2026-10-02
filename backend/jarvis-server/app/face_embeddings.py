"""Face detection + embedding via insightface -- lazy-loaded so app boot is fast
(mirrors embeddings.py's pattern for the text model).

Model: insightface 'buffalo_l' pack, which bundles a face detector (SCRFD) and a
recognition model (ArcFace, 512-dim) behind a single FaceAnalysis.get(image) call --
no separate detector needs to be wired up. Runs on CPU (ctx_id=-1); no paid API,
no network calls at inference time (model weights are downloaded once on first use).
"""
import base64
from dataclasses import dataclass
from typing import List, Optional, Tuple

import numpy as np

_app = None

# Enrollment quality gates. Motivated by real production data: a reference photo saved
# 2026-08-07 scored only 0.29-0.36 against the *same* person across 7+ later attempts,
# while a re-enrolled photo of that person scored 0.75-0.87. A poor reference photo
# silently and permanently degrades every future identify, and nothing used to stop one
# from being stored -- these gates make a bad capture fail loudly at save time instead.
#
# det_score is SCRFD's detection confidence; a low value usually means a heavily
# occluded/blurred/extreme-angle face that ArcFace will also embed poorly.
_MIN_DET_SCORE = 0.65
# Face too small in frame == too few pixels for ArcFace's 112x112 input to be sharp
# after cropping, which is the "standing too far away" case.
_MIN_FACE_PIXELS = 80
# Laplacian variance on the cropped face -- catches motion blur, which the detector
# often still scores confidently but which destroys embedding quality.
_MIN_SHARPNESS = 12.0


@dataclass
class FaceQuality:
    det_score: float
    face_pixels: int
    sharpness: float

    @property
    def is_good_enough_to_enroll(self) -> bool:
        return (
            self.det_score >= _MIN_DET_SCORE
            and self.face_pixels >= _MIN_FACE_PIXELS
            and self.sharpness >= _MIN_SHARPNESS
        )

    def rejection_reason(self) -> Optional[str]:
        """Korean, user-facing -- relayed verbatim by the root agent, so it must say what
        the user should physically change, not which metric failed."""
        if self.det_score < _MIN_DET_SCORE:
            return "얼굴이 또렷하게 안 보여요. 정면으로 봐주시겠어요?"
        if self.face_pixels < _MIN_FACE_PIXELS:
            return "얼굴이 너무 작게 나왔어요. 조금 더 가까이서 다시 찍어주시겠어요?"
        if self.sharpness < _MIN_SHARPNESS:
            return "사진이 흔들렸어요. 잠깐 멈춰서 다시 찍어주시겠어요?"
        return None

    def as_dict(self) -> dict:
        return {
            "det_score": round(self.det_score, 4),
            "face_pixels": self.face_pixels,
            "sharpness": round(self.sharpness, 2),
        }


def _get_app():
    global _app
    if _app is None:
        # Imported lazily so `from app.main import app` doesn't pull onnxruntime/cv2
        # upfront, same reasoning as embeddings.py's lazy sentence-transformers import.
        from insightface.app import FaceAnalysis

        _app = FaceAnalysis(name="buffalo_l")
        _app.prepare(ctx_id=-1, det_size=(640, 640))
    return _app


def _measure_quality(img, face) -> FaceQuality:
    import cv2

    x1, y1, x2, y2 = [int(v) for v in face.bbox]
    face_pixels = min(x2 - x1, y2 - y1)

    # Clamp to the image before cropping -- SCRFD can return a bbox that runs slightly
    # past the frame edge for a face at the border, and a negative index would silently
    # wrap around and measure the wrong region.
    h, w = img.shape[:2]
    crop = img[max(0, y1):min(h, y2), max(0, x1):min(w, x2)]
    if crop.size == 0:
        sharpness = 0.0
    else:
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())

    return FaceQuality(
        det_score=float(face.det_score),
        face_pixels=int(face_pixels),
        sharpness=sharpness,
    )


def embed_face_from_base64(
    image_base64: str,
) -> Tuple[Optional[List[float]], int, Optional[FaceQuality]]:
    """Detects faces in the given base64 image and returns (embedding, face_count, quality).

    embedding is a 512-dim L2-normalized vector, only when exactly one face is found.
    embedding is None when face_count == 0 (no face) or face_count > 1 (ambiguous --
    caller should ask the user to recapture with a single person in frame rather than
    guessing which face was meant).

    quality is measured whenever exactly one face was found, and is returned even when
    it fails the enrollment gates -- identify (matching) deliberately still runs on a
    mediocre probe image, since the caller only has to decide *who* this is, not whether
    to permanently store it. Only enrollment (create_person / add face) refuses on
    quality, via FaceQuality.is_good_enough_to_enroll.
    """
    import cv2

    raw = base64.b64decode(image_base64)
    arr = np.frombuffer(raw, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        return None, 0, None

    faces = _get_app().get(img)
    if len(faces) != 1:
        return None, len(faces), None

    face = faces[0]
    return face.normed_embedding.tolist(), 1, _measure_quality(img, face)
