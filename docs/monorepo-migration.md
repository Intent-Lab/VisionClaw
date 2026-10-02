# 프론트엔드·백엔드 저장소 통합

## 범위

- 기준 브랜치: `feat/realtime-task-orchestration` (`b1abf22`).
- 작업 브랜치: `refactor/frontend-backend-monorepo`.
- 클라이언트의 `samples/`, `assets/`, 관련 문서를 `frontend/`로 이동.
- 최신 원격 `blockchainMania/JarvisMemoryServer`의 추적 파일만 `backend/`로 가져옴.
- 백엔드 원본: `blockchainMania/JarvisMemoryServer`, main `85b960b`.
- 백엔드 `.git`, 실제 `.env`, 데이터, 모델 및 가상환경은 복사하지 않음.
- 기존 백엔드 저장소와 원격 저장소는 변경하지 않음. 백엔드 과거 이력은 가져오지 않고 출처만 기록.
- 기존 `ContactActionManager.kt` 로컬 수정은 이동된 파일에 그대로 보존.

## 경로와 실행

| 이전 | 이후 |
|---|---|
| `samples/CameraAccessAndroid` | `frontend/samples/CameraAccessAndroid` |
| `samples/CameraAccess` | `frontend/samples/CameraAccess` |
| `assets` | `frontend/assets` |
| 별도 백엔드 저장소 | `backend` |

Android Studio 프로젝트를 새 경로에서 다시 여세요. Gradle 캐시에는 이전 절대 경로가
남을 수 있으므로 이동 후 클린 빌드로 확인합니다. iOS 내부 경로는 유지했습니다.
백엔드는 `cd backend/jarvis-server` 후 README의 설정·실행 절차를 따릅니다.

## 비밀 설정 정리

- 기존 Git 이력 자동 검사: 클라이언트 197개 커밋에서는 Gitleaks 탐지 없음.
  최신 백엔드 원본 35개 커밋에서는 과거 README의 인증 헤더 후보 1건 탐지
  (`f661ce79`, 91행). 현재 README에는 없으며 실제 사용 여부는 확인하지 않음.
  백엔드 과거 이력을 통합 저장소에 가져오지 않았음. 탐지 결과는 유출 부재를 보증하지 않음.
- 기존 샘플 Android 서명키와 고정 비밀번호가 존재했음.
  서명키 파일은 로컬에 보존하지만 새 구조에서는 Git에서 제외하고 기본 디버그 서명 사용.
  과거 Git 이력에 남은 서명키를 운영 서명용으로 사용하면 안 됨.
- 백엔드 고정 개발 API 키 및 DB 비밀번호 기본값 제거.
  `API_KEY`, `DATABASE_URL` 미설정 시 명시적 오류로 시작을 중단.
- Compose DB 비밀번호는 `POSTGRES_PASSWORD` 환경변수로 전달.
  DB 공개 포트는 localhost에만 바인딩.
- 이미 생성된 DB 볼륨의 비밀번호는 자동 변경하지 않음.
- 루트 ignore 규칙을 이동된 경로에 맞추고 로컬 비밀 파일 제외 규칙 추가.

## 제한 및 공개

폴더 통합이며 API 계약 통합이나 데이터 이관은 수행하지 않았습니다.
백엔드는 최신 원격 버전이며 원본의 `jarvis-server`, `streaming-server`, Android 보조 앱을 유지합니다.
실제 DB·모델·외부 서비스와의 통합 테스트는 수행하지 않았습니다.
원격 `jarvis-integration`의 후속 변경은 별도 병합이 필요합니다.
원본 백엔드는 비공개였으며, 사용자의 명시적 공개·푸시 승인에 따라 통합 브랜치를 공개 원격에 푸시합니다.

## 검증 결과

- 이동 후 Android APK 빌드 성공, JVM 테스트 27개 통과.
- 이전 절대 경로가 남은 `.cxx`와 빌드 산출물을 정리한 후 새 경로에서 재생성.
- 최신 백엔드 Python 전체 구문 검사 통과.
- 필수 설정 정상 값 및 누락·예제 값 거부 4가지 검사 통과.
- Docker Compose 설정 검증 및 테스트 셸 스크립트 구문 검사 통과.
- 보조 Android 앱의 사설 IP 두 곳을 localhost로 변경. 실제 스트리밍 사용 시
  해당 서버 주소를 로컬 환경에 맞춰 설정해야 함. 보조 앱 빌드 및 실기기 검증은 미수행.
- 실제 DB, 임베딩 모델, OAuth 및 외부 API를 실행하는 통합 테스트는 미수행.
- 최종 커밋 대상 파일 Gitleaks 검사: 탐지 0건. 실제 로컬 비밀 파일은 검사 복사본 및 커밋 대상에서 제외.
