# Bitchat Android - Agent Guide

This document provides context, architectural insights, and development standards for AI agents working on the Bitchat Android codebase.

## 1. Project Overview
**Bitchat** is a decentralized, off-grid communication application focused on privacy and censorship resistance. It utilizes mesh networking (primarily Bluetooth LE and Tor/Arti) to enable peer-to-peer messaging without centralized servers.

**Key Technologies:**
- **Language:** Kotlin (JVM Target 1.8)
- **UI Framework:** Flutter (primary frontend)
- **Backend UI:** Jetpack Compose (Material 3) for legacy components
- **Asynchronous:** Kotlin Coroutines & Flow
- **Networking:** Bluetooth Low Energy (BLE), OkHttp
- **Database:** Google Firestore (authentication & health data)
- **Architecture:** MVVM with Clean Architecture principles
- **Build System:** Gradle (Kotlin DSL)

## 2. Architecture & Directory Structure
The application follows a clean architecture pattern, heavily modularized by feature within the `app` module.

**Root Package:** `com.bitchat.android`

| Directory | Purpose |
|-----------|---------|
| `ui/` | **Presentation Layer**: Jetpack Compose screens, themes, and ViewModels. |
| `service/` | **Core Service**: Contains `MeshForegroundService`, managing persistent background connectivity. |
| `mesh/` | **Mesh Networking**: Logic for peer discovery, advertising, and message routing. |
| `protocol/` | **Wire Protocol**: Definitions of messages exchanged between peers. |
| `crypto/` | **Security**: Cryptographic primitives and key management. |
| `noise/` | **Encryption**: Implementation of the Noise Protocol Framework for secure channels. |
| `identity/` | **User Identity**: Management of user profiles and public/private keys. |
| `features/` | **App Features**: Sub-modules for `voice`, `file`, and `media` handling. |
| `geohash/` | **Location**: Utilities for location-based features and geohashing. |
| `net/` | **Networking**: General network utilities and abstractions. |

## 3. Key Components

### UI Layer
- **Primary Framework**: Flutter (located in `flutter_ui/`) handles the main application UI and user-facing functionality.
- **Legacy Components**: Jetpack Compose (Material 3) available for backend/legacy Android components.
- **Flutter Features**: Registration/Login, health information packet upload, messaging interface.
- **State Management**: ViewModel with StateFlow for Android components; Flutter Provider pattern for Flutter UI.
- **Theme**: Custom theme definitions in both `ui/theme` (Android) and `flutter_ui/` (Flutter).

### Networking & Connectivity
- **MeshForegroundService**: The critical component that keeps the mesh network alive. It manages the lifecycle of BLE scanning/advertising and other transport layers.
- **BLE Stack**: Located in `mesh/` and `net/`, handles the intricacies of Android Bluetooth interactions.

### Authentication & Data Management
- **Firestore Integration**: Used for user registration/login and health information packet storage. Provides secure cloud-based authentication and data persistence.
- **Health Data Upload**: Integrated with Firestore for secure transmission and storage of health information packets from Flutter UI.

## 4. Development Standards

### Code Style
- **Kotlin**: Adhere to official Kotlin coding conventions.
- **Compose**: Use functional components. Hoist state to ViewModels where possible.
- **Coroutines**: Use `suspend` functions for all I/O operations. strictly avoid blocking the main thread.
- **Naming**: Clear, descriptive names. Follow standard Android naming patterns (e.g., `*ViewModel`, `*Repository`, `*Screen`).

### Commit messages
- Title 與 description 一律使用**繁體中文**撰寫。
- 例外：`CONTEXT.md` 定義的領域語彙（Health Report、Status、Reporter、Broadcast Tier、Detail Tier、Severity、Severity Inflation、Relay Decision 等）維持原文，不要翻譯或改寫，以免與 `CONTEXT.md` 的 _Avoid_ 清單衝突。
- 其他技術識別字（類別名、檔名、指令、type prefix 如 `fix:` / `docs:`）同樣保留原文。

### Testing
- **Unit Tests**: Located in `app/src/test/`. Use for business logic, protocols, and utility testing.
- **Instrumented Tests**: Located in `app/src/androidTest/`. Use for UI and permission integration testing.
- **Execution**:
  - Unit: `./gradlew test`
  - Instrumented: `./gradlew connectedAndroidTest`

## 5. Critical Constraints & Gotchas
1.  **Permissions**: The app relies heavily on dangerous runtime permissions (Location, Bluetooth Scan/Connect/Advertise, Audio Recording). Always verify permission handling patterns in `MainActivity` or permission wrappers before adding new hardware features.
2.  **Hardware Dependency**: Features like BLE are difficult to emulate. When writing code for these, focus on robust error handling and defensive programming as hardware behavior can be flaky.
3.  **Background Limits**: Android enforces strict background execution limits. Network operations intended to persist must be tied to the `MeshForegroundService`.

## 6. Common Tasks
- **Build Debug APK**: `./gradlew assembleDebug`
- **Lint Check**: `./gradlew lint`
- **Clean Build**: `./gradlew clean`

## Agent skills

### Issue tracker

Issues live in GitHub Issues (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

---
*Note: This file is intended to assist AI agents in navigating and modifying the codebase efficiently. Always verify context by reading the actual files before making changes.*