"""Embedding model loader — lazy-loaded so app boot is fast.

Default: nlpai-lab/KURE-v1 (Korean-focused, BGE-M3 fine-tune, 1024-dim).
Swap via .env EMBEDDING_MODEL=... (e.g. BAAI/bge-m3). Same dim → no schema change.
"""
from typing import List, Sequence

import numpy as np

from .config import settings

_model = None


def get_model():
    global _model
    if _model is None:
        # Imported lazily so `from app.main import app` doesn't pull torch upfront.
        from sentence_transformers import SentenceTransformer

        _model = SentenceTransformer(
            settings.embedding_model,
            device=settings.embedding_device,
        )
    return _model


def embed_texts(texts: Sequence[str]) -> np.ndarray:
    """Returns (n, dim) float32, L2-normalized."""
    model = get_model()
    vecs = model.encode(
        list(texts),
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=False,
    )
    return vecs.astype("float32")


def embed_text(text: str) -> List[float]:
    return embed_texts([text])[0].tolist()
