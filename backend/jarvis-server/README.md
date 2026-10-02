> 통합 저장소에서는 `cd backend/jarvis-server` 후 실행합니다.
> 먼저 `.env.example`을 `.env`로 복사해 `POSTGRES_PASSWORD`, `DATABASE_URL`,
> `API_KEY`를 설정하세요. 예제의 `replace-with-*`는 실제 임의 값으로 바꿔야 합니다.
> DB 비밀번호와 URL의 비밀번호를 일치시키세요. 기존 DB 볼륨 비밀번호는 자동 변경되지 않습니다.
> 이 아래 명령은 `jarvis-server` 디렉터리를 기준으로 합니다.

# Jarvis Memory API

스마트 글라스 기반 자비스 OS의 개인 기억 서버입니다. Android 클라이언트의 Gemini Live가 음성 대화와 도구 판단을 맡고, 이 서버는 사람/미팅/니즈/일상 기억을 저장하고 벡터 검색합니다.

## 현재 구현 요약

```text
Android 앱
  -> Gemini Live 음성 대화
  -> Gemini function calling
  -> Jarvis Memory API
  -> Postgres JSONB + pgvector
```

일상 기억 저장은 아래 흐름입니다.

```text
사용자: "이거 저장해줘"
Gemini: capture_current_view 호출
Android 앱: 최신 카메라 이미지 1장 첨부
Gemini: 이미지 해석 + 사용자 메모 정리
Gemini: save_life_memory 호출
서버: 이미지 파일 저장 + JSONB 메타데이터 저장 + 텍스트 벡터화
```

검색은 서버에서 pgvector로 먼저 찾고, 클라이언트 Gemini가 검색 결과를 자연어로 합성해 답합니다.

## 일상 기억 저장 구조

현재 별도 `life_memories` 테이블을 만들지 않고 기존 `memories` 테이블을 확장해서 씁니다.

컬럼 기준:

| 컬럼 | 내용 |
| --- | --- |
| `captured_at` | 기억이 발생한 시각 |
| `text` | 검색용 텍스트. 사용자 메모, AI 장면 해석, 사람 정보를 합친 문장 |
| `embedding` | `text`를 임베딩한 벡터 |
| `related_person_ids` | 연결된 사람 UUID 목록 |
| `source` | `camera`, `voice`, `manual`, `derived` |
| `metadata` | JSONB. 사용자 메모, AI 해석, 사람 텍스트, 이미지 경로 등 |

`metadata` 예시:

```json
{
  "memory_type": "life_scene",
  "user_note": "이 사람은 오늘 만난 투자자",
  "ai_interpretation": "회의실로 보이며, 테이블 위에 노트북과 문서가 있습니다.",
  "people_text": "김민수, 투자자, 오늘 처음 만남",
  "image_path": "/.../data/memory-images/uuid.jpg",
  "image_mime_type": "image/jpeg",
  "image_size_bytes": 123456
}
```

서버는 이미지를 해석하지 않습니다. 이미지는 Android 앱이 Gemini에게 1회 전달하고, Gemini가 만든 `ai_interpretation`을 서버가 저장합니다.

Personal memory & CRM API for the Jarvis project — visual memory + voice AI for
smart glasses. Phase 1 (this repo) is the **server**: stores people / meetings /
needs / episodic memories with vector search.

## Stack

- **FastAPI** (Python 3.11+)
- **Postgres + pgvector** (via Docker)
- **Embeddings** in-process, CPU:
  - default `nlpai-lab/KURE-v1` (Korean-focused, BGE-M3 한국어 파인튜닝)
  - swap to `BAAI/bge-m3` via `.env` (same 1024-dim → no schema change)
- **No external API calls** — runs $0 in API costs.

## Quick start

```bash
# 1. Start DB
docker compose up -d

# 2. Python deps  (first time: ~3GB — sentence-transformers pulls torch)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 3. Env
cp .env.example .env  # edit API_KEY before exposing

# 4. Seed dummy data
#    First run downloads the embedding model (~2GB, ~1-2min on a decent connection)
python scripts/seed.py

# 5. Run API
uvicorn app.main:app --reload --port 8000

# 6. Hit the 4 target commands
bash test_commands.sh
```

Interactive docs: <http://localhost:8000/docs>

## Endpoints

| Method | Path                            | Purpose |
|--------|---------------------------------|---------|
| POST   | `/people`                       | Create person (optionally with face_embedding) |
| GET    | `/people/{id}`                  | Get person |
| POST   | `/people/search`                | Search by face_embedding OR name/alias/org text |
| POST   | `/meetings`                     | Create meeting (summary auto-embedded) |
| GET    | `/meetings/{id}`                | Get meeting |
| POST   | `/meetings/search`              | Vector search meetings (+ time / person filters) |
| POST   | `/memory/save`                  | Save episodic memory |
| POST   | `/memory/life/save`             | Save daily life memory with user note, AI scene interpretation, people text, and optional image |
| POST   | `/memory/search`                | Vector search memories (+ time / person filters) |
| POST   | `/needs`                        | Save a need (extracted from meeting transcript) |
| GET    | `/needs/by-person/{id}`         | Needs for a person |
| GET    | `/people/{id}/context`          | Bundle (person + needs + recent meetings) for proposal synthesis |
| GET    | `/health`                       | Liveness + model info |

All endpoints require `X-API-Key` header.

## Maps to the 4 target commands

| User says                                          | Endpoint flow |
|----------------------------------------------------|---------------|
| "방금 만난 사람 저장해줘"                          | `POST /people` + `POST /meetings` |
| "이 사람 전에 어디서 만났지?"                      | `POST /people/search` (face) → `GET /people/{id}` |
| "지난번 배터리 부품사 미팅에서 나온 니즈?"         | `POST /meetings/search` → `GET /needs/by-person/{id}` |
| "이 사람이 관심 있어 할 제안 포인트?"              | `GET /people/{id}/context` → client Gemini synthesizes |
| "이거 저장해줘"                                  | client `capture_current_view` → `POST /memory/life/save` |
| "지난주에 본 명함 찾아줘"                         | `POST /memory/search` → client Gemini synthesizes |

## Embedding model — swap & compare

Default = KURE-v1 (Korean meeting content). To try BGE-M3:

```
EMBEDDING_MODEL=BAAI/bge-m3   # .env
```

Re-seed (`python scripts/seed.py`) for apples-to-apples retrieval comparison.
Quick A/B on a Korean test set without touching the DB:

```bash
python scripts/eval_embeddings.py
```

## Why this shape

- **No server-side LLM.** Proposal points etc. are synthesized by the *client*
  (Gemini Live) using context returned by `/people/{id}/context`.
  Server stays cheap, deterministic, and offline-friendly.
- **Face embeddings come from the phone.** JarvisAndroidClient 또는 기존 Android
  face pipeline의 TFLite (FaceNet
  / MobileFaceNet) already outputs them. Server only stores and searches —
  it does not run a face model.
- **OpenClaw skipped.** Gemini Live calls these endpoints directly via
  function-calling. Add OpenClaw later only when external-app actions
  (messaging, calendar, web search) are needed — not for memory itself.

## Connecting from JarvisAndroidClient

In JarvisAndroidClient's `GeminiConfig`, declare these as functions (instead of one
`execute` tool):

```
save_person(name, org, role, face_embedding?)
search_people(face_embedding|query, top_k)
save_meeting(title, person_ids, started_at, summary, transcript?)
save_memory(text, captured_at, related_person_ids?, source)
save_life_memory(captured_at, user_note, ai_interpretation, people_text?, related_person_ids?, source)
search_memory(query, top_k, time_from?, time_to?, person_id?)
search_meetings(query, top_k, time_from?, time_to?, person_id?)
save_need(person_id, meeting_id?, text, category)
get_proposal_context(person_id)
```

Each maps 1:1 to an endpoint above.

## Next milestones

- [ ] JarvisAndroidClient `ToolCallRouter` HTTP client to these endpoints
- [ ] Gemini Live function declarations
- [ ] Client-side: meeting transcript → needs auto-extraction (Gemini Flash)
- [ ] Phase 3: visual memory (SigLIP 2 / jina-clip-v2) for "그 빨간 책" 검색
- [ ] Production: TLS, key rotation, RLS, backups
