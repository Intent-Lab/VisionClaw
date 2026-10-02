#!/usr/bin/env bash
# Exercise the 4 target user commands against the running API.
# Requires: jq, curl, server running on $BASE (default localhost:8000), and
# `python scripts/seed.py` already run for the search commands to find data.
set -euo pipefail

BASE=${BASE:-http://localhost:8000}
: "${API_KEY:?Set API_KEY to the value in backend/jarvis-server/.env}"
H="X-API-Key: $API_KEY"

echo "════ 1. 방금 만난 사람 저장해줘 ════"
NEW_ID=$(curl -s -X POST "$BASE/people" \
  -H "$H" -H "Content-Type: application/json" \
  -d '{"name":"홍길동","org":"테스트회사","role":"이사"}' | jq -r .id)
echo "  ✓ new person id: $NEW_ID"
NOW=$(date -u +%FT%TZ)
curl -s -X POST "$BASE/meetings" \
  -H "$H" -H "Content-Type: application/json" \
  -d "{\"title\":\"테스트 미팅\",\"person_ids\":[\"$NEW_ID\"],\"started_at\":\"$NOW\",\"summary\":\"단가 협상 진행. 결정 시한 12월.\"}" \
  | jq '{id, title, started_at}'

echo ""
echo "════ 2. 이 사람 전에 어디서 만났지? (이름으로 검색) ════"
PERSON=$(curl -s -X POST "$BASE/people/search" \
  -H "$H" -H "Content-Type: application/json" \
  -d '{"query":"박부장","top_k":1}' | jq -r '.[0].person.id // empty')
if [[ -z "$PERSON" ]]; then
  echo "  (seed 데이터 없음 — scripts/seed.py 먼저 실행하세요)"; exit 0
fi
echo "  ✓ matched person id: $PERSON"
curl -s "$BASE/people/$PERSON" -H "$H" | jq '{name, org, first_met_at, last_met_at}'

echo ""
echo "════ 3. 지난번 배터리 부품사 미팅에서 나온 니즈 ════"
echo "── 의미 검색으로 미팅 찾기"
curl -s -X POST "$BASE/meetings/search" \
  -H "$H" -H "Content-Type: application/json" \
  -d '{"query":"배터리 부품사 미팅","top_k":2}' \
  | jq '.[] | {title, started_at, summary}'
echo ""
echo "── 그 사람의 needs 전체"
curl -s "$BASE/needs/by-person/$PERSON" -H "$H" \
  | jq '.[] | {text, category}'

echo ""
echo "════ 4. 이 사람이 관심 있어 할 제안 포인트 (컨텍스트 번들) ════"
echo "── Gemini Live가 받아서 합성할 컨텍스트"
curl -s "$BASE/people/$PERSON/context" -H "$H" \
  | jq '{
      person: .person | {name, org, role},
      needs: [.needs[] | {text, category}],
      recent_meetings: [.recent_meetings[] | {title, started_at, summary}]
    }'
