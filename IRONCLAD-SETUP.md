# OpenGlasses — IronClad Setup Guide

Kyle's step-by-step to get OpenGlasses running with our local AI stack.

---

## Prerequisites

- [ ] Mac with Xcode 26+
- [ ] iPhone (iOS 26+)
- [ ] Ray-Ban Meta smart glasses
- [ ] Meta developer account

---

## Step 1: Meta Developer Account

1. Go to **wearables.developer.meta.com**
2. Create account + organization + app
3. Note your **Meta App ID** and **Client Token**
4. In Meta dashboard → iOS settings, enter your Apple Team ID, Bundle ID, and Universal Link URL

---

## Step 2: Configure Personal Files

### project.local.yml (in repo root — gitignored)

```yaml
options:
  developmentTeam: YOUR_APPLE_TEAM_ID

targets:
  OpenGlasses:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/OpenGlasses.entitlements
        DEVELOPMENT_TEAM: YOUR_APPLE_TEAM_ID
        INFOPLIST_FILE: Config/Info/Info.personal.plist

  GlassesActivityWidget:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/GlassesActivityWidget.entitlements
        DEVELOPER_TEAM: YOUR_APPLE_TEAM_ID
```

### Config/Info/Info.personal.plist (gitignored)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MWDAT</key>
    <dict>
        <key>AppLinkURLScheme</key>
        <string>https://ironclad.build/glasses</string>
        <key>ClientToken</key>
        <string>AR|YOUR_META_APP_ID|YOUR_CLIENT_TOKEN_HASH</string>
        <key>MetaAppID</key>
        <string>YOUR_META_APP_ID</string>
        <key>TeamID</key>
        <string>$(DEVELOPMENT_TEAM)</string>
    </dict>
</dict>
</plist>
```

### Config/Entitlements/Personal/OpenGlasses.entitlements (gitignored)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.homekit</key>
    <true/>
    <key>com.apple.developer.kernel.increased-memory-limit</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.openglasses.app</string>
    </array>
</dict>
</plist>
```

---

## Step 3: Build

```bash
cd OpenGlasses
brew install xcodegen
./Scripts/generate-xcodeproj.sh
open OpenGlasses.xcodeproj
```

In Xcode:
1. Select your iPhone as destination
2. Set signing team if prompted
3. Build & Run (⌘R)

---

## Step 4: In-App Configuration

### AI Models (Settings → AI Models)

Add these three models:

#### Fast: DeepSeek V4-Flash
- **Provider:** Custom
- **Name:** DeepSeek V4-Flash
- **API Key:** (any string, local model)
- **Model:** deepseek-v4-flash
- **Base URL:** `http://192.168.1.137:8001/v1/chat/completions`
- **Vision:** No

#### Balanced: VL-72B
- **Provider:** Custom
- **Name:** VL-72B
- **API Key:** (any string)
- **Model:** vl72b
- **Base URL:** `http://192.168.1.136:8001/v1/chat/completions`
- **Vision:** Yes

#### Best: GLM-5.1 (RunPod)
- **Provider:** Custom
- **Name:** GLM-5.1
- **API Key:** sk-ironclad
- **Model:** glm51
- **Base URL:** `https://flbsh4qgrq58n6-8000.proxy.runpod.net/v1/chat/completions`
- **Vision:** No

### Model Routing (Settings → AI Models → Model Routing)
- **Fast:** DeepSeek V4-Flash
- **Balanced:** VL-72B
- **Best:** GLM-5.1
- Enable auto-routing

### OpenClaw Gateway (Settings → Services)

#### Legacy config:
- **Enabled:** On
- **Connection Mode:** LAN
- **LAN Host:** `http://192.168.1.132`
- **Port:** 18789
- **Tunnel Host:** (leave empty)
- **Gateway Token:** (Alfred's gateway token)

#### Multi-Gateway config (preferred):
Add gateway:
- **Name:** Alfred
- **Provider:** OpenClaw
- **LAN Host:** `http://192.168.1.132`
- **Port:** 18789
- **Tunnel Host:** (leave empty or add Tailscale URL)
- **Token:** (Alfred's gateway token)
- **Connection Mode:** Auto
- **Enabled:** On
- **Priority:** 0

### Persona (Settings → Personas)

Create "Alfred" persona:
- **Wake Phrase:** "hey alfred"
- **Alternative Phrases:** "hey alfredd", "hey el fred"
- **Model:** (use active or VL-72B for vision tasks)
- **System Prompt:**
```
You are Alfred, Kyle Alexander's personal AI assistant. You are connected through his Meta Ray-Ban smart glasses. You can see what he sees and hear what he says.

Your primary job right now is helping with IronClad AI platform development. When Kyle points at a UI issue, describe what you see and suggest or implement fixes through the OpenClaw gateway.

Rules:
- Be direct and concise — responses are spoken through the glasses
- When you see a UI bug, describe it precisely and offer to fix it
- You have full access to the codebase and deployment pipeline through the gateway
- Never say you can't see — you have the camera feed
```

---

## Step 5: Pair Glasses

1. Open **Meta AI app** on iPhone
2. Settings → About → tap version number 5 times → toggle **Developer Mode** on
3. Pair your Ray-Ban Meta glasses

---

## Step 6: Test

Say **"Hey Alfred, what do you see?"** — the glasses camera activates, VL-72B analyzes the frame, and the result routes through OpenClaw to Alfred.

---

## Our Local AI Stack

| Service | Endpoint | Purpose |
|---------|----------|---------|
| Alfred (OpenClaw) | 192.168.1.132:18789 | Gateway + agent |
| VL-72B | 192.168.1.136:8001/v1 | Vision (scene analysis) |
| DeepSeek V4-Flash | 192.168.1.137:8001/v1 | Fast LLM (1M context) |
| GLM-5.1 | flbsh4qgrq58n6-8000.proxy.runpod.net/v1 | Best reasoning |
| Whisper-large-v3 | 192.168.1.138:8001/v1 | STT (Phase 2) |
| Kokoro TTS | 192.168.1.138:8007 | TTS (Phase 2) |
| GLM-OCR | 192.168.1.138:8005/v1 | OCR (Phase 2) |
