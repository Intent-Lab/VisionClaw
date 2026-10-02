"""A/B compare BGE-M3 vs KURE-v1 on a small Korean retrieval set.

Run AFTER `pip install -r requirements.txt`. First run downloads both models
(~2GB each). Use this to decide which embedding model fits your data.

Usage:
    python scripts/eval_embeddings.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np  # noqa: E402

MODELS = [
    "BAAI/bge-m3",
    "nlpai-lab/KURE-v1",
]

CORPUS = [
    "10kWh 배터리 1000개 단가 협상. 안전성 인증 자료 요청. Q4 결정.",
    "차세대 셀 화학에 대한 기술 교류. CTO가 LFP 안전성에 관심 강함.",
    "단가 안 1차안 거절. 12월 결정 시한. 안전성 보증 우려 재차 강조.",
    "오늘 아침 강남 스타벅스에서 회의함.",
    "전고체 배터리 입문 책을 읽고 있다.",
    "공동 R&D 예산 한정적이라 단계적 협력 제안.",
]

QUERIES = [
    "배터리 부품사 미팅에서 나온 니즈",
    "안전성 인증",
    "지난번 만난 사람이 단가 얘기한 적 있나",
    "LFP 화학에 관심 있는 사람",
    "1시간 전에 본 책",
]


def eval_model(name: str) -> None:
    print(f"\n────────  {name}  ────────")
    from sentence_transformers import SentenceTransformer
    m = SentenceTransformer(name, device="cpu")
    C = m.encode(CORPUS, normalize_embeddings=True, convert_to_numpy=True)
    for q in QUERIES:
        qv = m.encode([q], normalize_embeddings=True, convert_to_numpy=True)[0]
        scores = C @ qv
        order = np.argsort(-scores)
        print(f"\nQ: {q}")
        for rank, idx in enumerate(order[:3], 1):
            print(f"  {rank}. ({scores[idx]:.3f}) {CORPUS[idx][:70]}")


if __name__ == "__main__":
    for m in MODELS:
        eval_model(m)
