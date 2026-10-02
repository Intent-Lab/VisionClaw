# Jarvis Glass Android Client

Meta Ray-Ban 스마트 글라스 또는 안드로이드 폰 카메라를 사용하는 자비스 OS 안드로이드 클라이언트입니다.

Gemini Live가 음성 대화를 담당하고, Jarvis Memory API가 사람/미팅/일상 기억을 저장하고 검색합니다. OpenClaw 이름이 일부 클래스에 남아 있지만, 현재 안드로이드 통합은 Jarvis Memory API를 직접 호출합니다.

## 현재 동작 구조

```text
사용자 음성
  -> Gemini Live
  -> Gemini가 도구 호출 판단
  -> Android 앱 ToolCallRouter
  -> Jarvis Memory API 또는 앱 내부 로컬 도구
  -> Gemini가 결과를 음성으로 답변
```

시각 정보는 비용을 줄이기 위해 계속 Gemini로 보내지 않습니다.

```text
평상시:
음성만 Gemini Live로 전송

현재 시야가 필요한 질문:
Gemini가 capture_current_view 호출
앱이 최신 카메라 프레임 1장만 Gemini에 첨부
Gemini가 이미지 기반으로 답변

일상 기억 저장:
Gemini가 capture_current_view 호출
앱이 최신 이미지 1장 첨부
Gemini가 ai_interpretation 생성
Gemini가 save_life_memory 호출
서버가 JSONB + 이미지 + 벡터로 저장
```

예시:

- "이거 저장해줘"
- "지금 보는 거 기억해줘"
- "내가 요리하다가 이 재료가 뭔지 모르겠는데 너는 알아?"
- "앞에 있는 사람 누구야?"
- "이 문서 읽어줘"
- "지난주에 본 명함 찾아줘"

## 주요 기능

- Meta Ray-Ban 글라스 카메라 스트림 수신
- 폰 카메라 모드로 테스트
- Gemini Live 음성 입력/출력
- Gemini function calling 기반 Jarvis 도구 호출
- `capture_current_view` 로컬 도구로 현재 프레임 1장만 온디맨드 전송
- `save_life_memory`로 일상 장면 이미지/메모/AI 해석 저장
- `search_memory`, `search_people`, `search_meetings` 등 메모리 검색

## 사전 준비

- Android Studio
- Android SDK
- Meta Ray-Ban 글라스 또는 테스트용 안드로이드 폰
- Gemini API key
- GitHub token
- 실행 중인 Jarvis Memory API 서버

GitHub token은 Meta DAT Android SDK를 GitHub Packages에서 받기 위해 필요합니다.

## 설정

Android Studio에서 아래 폴더를 프로젝트로 엽니다.

```bash
~/Desktop/develop/JarvisAndroidClient/samples/CameraAccessAndroid
```

`local.properties`에 GitHub token을 넣습니다.

```properties
github_token=YOUR_GITHUB_TOKEN
```

`Secrets.kt`를 만듭니다.

```bash
cd app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess
cp Secrets.kt.example Secrets.kt
```

`Secrets.kt`에서 아래 값을 채웁니다.

```kotlin
const val geminiAPIKey = "YOUR_GEMINI_API_KEY"
const val jarvisApiBase = "http://YOUR_MAC.local:8000"
const val jarvisApiKey = "dev-secret-change-me"
```

Mac Bonjour 이름은 아래 명령으로 확인합니다.

```bash
scutil --get LocalHostName
```

예를 들어 결과가 `yskim-mbp`라면:

```kotlin
const val jarvisApiBase = "http://yskim-mbp.local:8000"
```

## 실행

1. Android Studio에서 Gradle Sync를 실행합니다.
2. 폰을 USB 또는 wireless ADB로 연결합니다.
3. Run configuration에서 `app`을 선택합니다.
4. Run 버튼을 누릅니다.
5. 앱에서 `Start on Phone` 또는 `Start Streaming`을 누릅니다.
6. AI 버튼을 눌러 Gemini Live 세션을 시작합니다.

## 테스트 명령

```text
박부장 찾아줘
지난번 배터리 부품사 미팅에서 나온 니즈 알려줘
이 사람한테 어떤 제안 좋을지 알려줘
이거 저장해줘
내가 요리하다가 이 재료가 뭔지 모르겠는데 너는 알아?
지난주에 본 명함 찾아줘
```

## 비용 관련 설정

Settings의 `Video Streaming`은 기본값이 꺼져 있습니다.

이 값을 켜면 Gemini Live로 주기적인 비디오 프레임이 전송되어 비용이 커질 수 있습니다. 일상 사용에서는 꺼둔 상태를 권장합니다. 현재 시야가 필요한 경우 Gemini가 `capture_current_view` 도구를 호출하고, 앱이 최신 이미지 1장만 전송합니다.

## 주요 코드

| 파일 | 역할 |
| --- | --- |
| `gemini/GeminiLiveService.kt` | Gemini Live WebSocket, 음성/이미지 전송 |
| `gemini/GeminiSessionViewModel.kt` | 세션 상태, 현재 시야 캡처 도구 처리 |
| `openclaw/ToolCallModels.kt` | Gemini function declarations |
| `openclaw/ToolCallRouter.kt` | Gemini 도구 호출 라우팅 |
| `openclaw/OpenClawBridge.kt` | Jarvis Memory API HTTP 클라이언트 |
| `openclaw/VisualMemoryFrameStore.kt` | 최신 카메라 프레임 JPEG 캐시 |
| `settings/SettingsManager.kt` | Gemini/Jarvis 설정과 기본 시스템 프롬프트 |
| `stream/StreamViewModel.kt` | 글라스 카메라 스트림 처리 |

## 문제 해결

Gradle Sync 401:

```text
local.properties의 github_token이 없거나 권한이 부족합니다.
gh auth refresh -s read:packages 후 gh auth token 값을 다시 넣습니다.
```

폰에서 Jarvis API 접속 실패:

```text
폰과 Mac이 같은 Wi-Fi인지 확인합니다.
uvicorn이 --host 0.0.0.0으로 떠 있어야 합니다.
폰 브라우저에서 http://YOUR_MAC.local:8000/health 를 열어 확인합니다.
```

글라스 카메라가 끊김:

```text
Meta AI 앱 연결 상태, Bluetooth, 권한을 확인합니다.
현재 프로젝트는 DAT SDK 0.5.0 기준으로 낮은 품질/낮은 FPS 스트림을 사용합니다.
```
