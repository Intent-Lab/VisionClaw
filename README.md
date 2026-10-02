# Jarvis

스마트 글라스 클라이언트와 메모리 API를 한 저장소에서 관리합니다.

```text
frontend/
  samples/CameraAccessAndroid/  # Android 클라이언트
  samples/CameraAccess/         # iOS 클라이언트 및 기존 보조 서버
  assets/
backend/                       # FastAPI + Postgres/pgvector
  jarvis-server/               # 메모리 API 및 DB 설정
  streaming-server/            # 스트리밍 보조 서버
  app/                         # 원본의 얼굴 인식 Android 보조 앱
docs/                          # 저장소 통합 기록
```

## 클라이언트

기존 Android·iOS 내부 디렉터리 구조는 유지하고 `frontend/` 아래로 옮겼습니다.
Android Studio에서 `frontend/samples/CameraAccessAndroid`를 엽니다.

```bash
cd frontend/samples/CameraAccessAndroid
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

설정 및 사용법: [클라이언트 문서](frontend/README.md),
[Android 문서](frontend/samples/CameraAccessAndroid/README.md).
로컬 `Secrets.kt`, `Secrets.swift`, `local.properties` 및 서명키는 커밋하지 않습니다.
Android 디버그 빌드는 Android 도구의 기본 로컬 디버그 키를 사용합니다.
기존 설치본과 서명이 다를 경우 업데이트 설치가 실패할 수 있습니다.

## 백엔드

[백엔드 실행 방법](backend/README.md)을 따라 `backend/jarvis-server/.env.example`을
`backend/jarvis-server/.env`로 복사하고 DB 비밀번호와 API 키를 설정합니다.
실제 설정, 데이터, 모델, 가상환경은 저장소에 포함하지 않습니다.

가져온 백엔드는 `blockchainMania/JarvisMemoryServer` 원격 main의 `85b960b` 버전입니다.
원본 백엔드 전체 구조를 유지했으며, 폴더 통합 후 실제 서버 연동은 별도 검증이 필요합니다.
기존 원격 클라이언트 브랜치의 후속 변경도 이 브랜치에 자동 병합하지 않았습니다.

## 변경 기록 및 공개 범위

[통합 변경사항](docs/monorepo-migration.md)을 참고하세요.
백엔드 원본은 비공개 저장소였으며, 사용자 승인에 따라 이 통합 저장소에 공개합니다.
기존 클라이언트 라이선스와 고지는 루트의 `LICENSE`, `NOTICE`에 유지합니다.
백엔드 공개 시에는 별도 라이선스 적용 범위를 확인해야 합니다.
