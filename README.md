# Shilpi Bondhu / Durga Puja (updated)

Flutter app for idol makers (Kolkata): finance khata (Bangla text → English translation → GPT), worker funds, reports/AI logs, and design tools.

Repo: [shashank1694/durgapuja-updated](https://github.com/shashank1694/durgapuja-updated)

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) (SDK **^3.9.2**, see `pubspec.yaml`)
- Android Studio / Xcode if building for device
- API keys (ask the maintainer — send via encrypted message; **never commit keys**)

## First-time setup

```bash
git clone https://github.com/shashank1694/durgapuja-updated.git
cd durgapuja-updated
git checkout main   # or with-translation
flutter pub get
```

### 1. API keys (required for AI features)

Secrets are **not** in the repo. Copy the example file and paste the keys you were given:

```bash
# Windows (PowerShell)
Copy-Item lib\config\api_keys.example.dart lib\config\api_keys.dart

# macOS / Linux
cp lib/config/api_keys.example.dart lib/config/api_keys.dart
```

Edit `lib/config/api_keys.dart` and set:

| Field | Used for |
|-------|----------|
| `openAI` | Finance GPT intent extraction, speech helpers |
| `openAIKey` | OpenAI image generation |
| `replicateApiKey` | SAM 2 / tap-to-edit selection |
| `kreaApiKey` | Krea image generation / enhancement |

`lib/config/api_keys.dart` is gitignored — do not commit it.

### 2. Optional `.env`

App loads `.env` at startup (see `lib/main.dart`). Krea code can also read `KREA_API_TOKEN` from `.env` if set.

```bash
# Windows
Copy-Item .env.example .env

# macOS / Linux
cp .env.example .env
```

You can leave `.env` minimal if everything is already in `api_keys.dart`.

### 3. Firebase

`lib/firebase_options.dart`, `android/app/google-services.json`, and `ios/Runner/GoogleService-Info.plist` are already in the repo for this project. Auth/sign-in needs a working Firebase project those files point to. If Firebase fails to init, the app may still open in a limited mode — check logs.

## Run

```bash
flutter devices
flutter run
# or
flutter build apk
```

## What a new person should know

### Finance flow (current)

1. User types Bangla (or English) in the finance screen **TextField** and taps **Submit** (mic is not used for this path).
2. On-device **ML Kit** translates Bangla → English when needed.
3. **GPT** (`gpt-4o-mini`) extracts intent/amount using the legacy JSON schema in `lib/services/gpt_service.dart`.
4. User confirms → saved to local **sqflite**; an entry is also written to **AI logs**.
5. Reports → **View All AI Transactions** → `/finance/ai-logs`.

Without valid `ApiKeys.openAI`, finance GPT calls will fail.

### Main areas in the app

- **Finance** — income/expense/worker payments via text + GPT
- **Reports / AI logs** — history of AI-parsed transactions
- **Design / image tools** — OpenAI / Krea / Replicate (need their keys)
- **Auth** — Firebase phone/email flows

### Branding

App name/branding uses **Shilpi Bondhu** assets under `assets/logo/` (launcher icon + splash).

## Troubleshooting

| Problem | What to check |
|---------|----------------|
| `api_keys.dart` missing / compile error | Copy from `api_keys.example.dart` |
| GPT / finance parse fails | `ApiKeys.openAI` valid OpenAI key |
| Image gen / Krea errors | `kreaApiKey` or `.env` `KREA_API_TOKEN` |
| Firebase / login issues | Network + Firebase console for this project’s config files |
| Translation fails offline | First run may need ML Kit model download; use English text to test GPT alone |

## Note on GitHub “8 months ago” dates

This repo was uploaded recently but **git history was preserved**. Files not changed in the latest commit still show the date of their last older commit. That is normal — not an incomplete upload.
