# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Initial setup
bundle install
bundle exec pod install

# Development (run in separate terminals)
npm start          # Metro bundler
npm run ios        # Build and launch in simulator

# Lint / Test
npm run lint
npm test
```

**Simulator:** Use `iPhone 17 Pro` (no iPhone 16 available).

**Xcode build (Swift compile check only):**
```bash
xcodebuild -project Identity.xcodeproj -scheme Identity -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Note: Swift compilation succeeds; linker fails on `DoubleConversion` (pre-existing React Native dep issue, not our code).

**Always open** `Identity.xcworkspace`, not `.xcodeproj`.

## Architecture

This is a React Native app where **React Native manages the AI model lifecycle** and **Swift/SwiftUI owns the entire UI layer**. React Native's JS thread is essentially a background worker for LLM inference.

### Bridge Pattern (EdgeAI)

```
SwiftUI → EdgeAI.generate(prompt) → RCT Promise
                                   ↓
                     emits EdgeAIRequest event to JS
                                   ↓
              JS runs llama.rn completion() on LLM context
                                   ↓
              JS calls EdgeAI.resolveRequest(requestId, text)
                                   ↓
                         Swift Promise resolves
```

Key files: `ios/EdgeAI.swift` (RCTEventEmitter), `ios/EdgeAI.m` (ObjC bridge), `App.tsx` (event listener + llama.rn context).

`EdgeAI.generate()` uses RCT callback pattern — wrap with `withCheckedContinuation` for async/await in Swift.

### Native Module → SwiftUI

`<NativeChatView>` in React → `requireNativeComponent('NativeChatView')` → `NativeChatViewManager.swift` → `TabContainerView` (SwiftUI root via `UIHostingController`).

### iOS Directory Structure

```
ios/
├── Core/           # AppConstants, AppError, AppLogger
├── Services/       # AIService, FileProcessingService, FileStorageService,
│                   # OCRService, PersistenceService, ValidationService
├── Coordinators/   # SummaryCoordinator, LockManager
├── Views/          # LockOverlayView, LoadingViews, ConversationHistorySheet
└── [root Swift]    # TabContainerView, NativeChatView, DocumentManager,
                    # DocumentModels, DocumentPreviewViews, etc.
```

`Services/`, `Core/`, `Coordinators/`, `Views/` use `PBXFileSystemSynchronizedRootGroup` — new files dropped in these directories are automatically included in the Xcode target.

### Key Patterns

**Logging:** Use `AppLogger` (not `print` or bare `Logger`) with the appropriate category: `persistence`, `fileStorage`, `fileProcessing`, `documents`, `ui`, `ai`, `sharing`, `conversion`, `general`. Exception: `RetrievalLogger` uses a local `Logger` because it's shared with the ShareExtension target.

**Error handling:** `do/catch` with typed `AppError` subtypes. Avoid `try?` unless the failure is truly inconsequential.

**Async:** Swift `async/await` throughout; `SummaryCoordinator` shows the canonical pattern for coordinating async AI + file operations.

**File I/O:** Go through `FileStorageService` (lazy loading, caching) rather than reading files directly.

**Document lifecycle:** `DocumentManager` (790 lines) owns CRUD; `PersistenceService` owns JSON serialization.

## Key Dependencies

- `llama.rn` — on-device LLM inference (initialized in `App.tsx`, used via EdgeAI bridge)
- `SSZipArchive` — DOCX extraction (CocoaPods)
- `react-native-fs` — file system access from JS
- Vision framework — OCR in `OCRService.swift`
- Core Data — document metadata (`DocumentModel.xcdatamodeld`)
