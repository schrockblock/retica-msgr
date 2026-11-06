# macOS Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The existing `ReTiCAMsgr` app target builds, launches and messages on macOS, sharing every view with iOS, with iOS behaviour unchanged.

**Architecture:** One multiplatform app target (iOS + native macOS, not Catalyst). iOS-only APIs are either wrapped in small cross-platform helpers in `ReTiCAMsgr/Platform/` or fenced with `#if os(iOS)`, with a Mac equivalent where one is cheap. No Mac-specific layout yet: that comes in later UI iterations.

**Tech Stack:** SwiftUI, AppKit (only where SwiftUI has no equivalent), TCA, Xcode 26 file-system-synchronized groups (new files under `ReTiCAMsgr/` join the app target automatically; no pbxproj edits beyond Task 1).

**Spec:** none. The user skipped the design conversation ("mechanical port, UI iterations later"); the decisions are recorded in Global Constraints below.

## Global Constraints

- Worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-macos`, branch `feat/macos`. Parallel tasks use sibling worktrees `ReTiCAMsgr-macos-<task>` (branches `feat/macos-<task>`) so the `../../../pods` path dependencies still resolve.
- `MACOSX_DEPLOYMENT_TARGET = 26.4` (matches `IPHONEOS_DEPLOYMENT_TARGET`), so there are no availability checks.
- Native macOS: `SUPPORTS_MACCATALYST = NO`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`.
- iOS behaviour and visuals must not change. Every `#if os(iOS)` branch keeps the existing code verbatim.
- The notification service extension stays iOS-only (`platformFilter = ios` on its embed and dependency).
- macOS never calls `runtime.backgrounded()`. A Mac app is not suspended, so its sockets stay open; `BackgroundTaskClient` stays at the package's `liveValue` on macOS.
- Push on macOS: register through `NSApplication` with the same bundle id `co.lithobyte.ReTiCaMsgr`. Push also owns the notification permission prompt, which local notifications depend on.
- iOS-only features with no cheap Mac equivalent are hidden on macOS, not reimplemented: camera QR scanning (`DataScannerViewController`), the camera avatar capture (`UIImagePickerController`), and the in-app mail composer (Mac uses the existing `mailto:` fallback).
- Fence modules with `#if canImport(UIKit)` (UIKit, MessageUI) and `#if os(iOS)` (iOS-only APIs).
- Temporary files go in `/tmp/ReTiCAMsgr/`. One shell command per Bash call: no pipes, no `&&`, no inline scripts.
- iOS build command: `xcodebuild -project ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ReTiCAMsgr/dd-<task>-ios build -quiet`
- macOS build command: `xcodebuild -project ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination platform=macOS -derivedDataPath /tmp/ReTiCAMsgr/dd-<task>-mac CODE_SIGNING_ALLOWED=NO build -quiet`

## Review Focus

1. **Keychain on macOS.** ReTiCAKeychain sets `kSecUseDataProtectionKeychain` and an access group. Without `keychain-access-groups` in the Mac entitlements, identity creation fails on first launch. Task 6 checks this with a real signed launch.
2. **App group container.** `PushStorage` uses `containerURL(forSecurityApplicationGroupIdentifier: "group.co.lithobyte.ReTiCaMsgr")`, which returns nil on a sandboxed Mac without the entitlement. Task 6's launch check covers it.
3. **Scene phase on Mac.** Hiding or minimising the window must not close the TCP socket (Task 2's code path). Task 6 checks: hide the app, send from the phone, and the message arrives.
4. **Avatar crop orientation.** The Mac crop path draws a CGImage with a flipped y axis. Task 3's crop test pins the top-left quadrant colour.
5. **Sheets in place of full-screen covers.** The attachment viewer and avatar cropper become sheets on Mac and need a usable size. Task 4 and Task 5 give them `.frame(minWidth: 480, minHeight: 480)` on macOS.

---

### Task 1: Foundation — multiplatform target, entitlements, platform helpers (sequential, before all others)

**Files:**
- Modify: `ReTiCAMsgr.xcodeproj/project.pbxproj`. The app target settings and the extension `platformFilter` were already applied by `/tmp/ReTiCAMsgr/macos_pbx.py` during recon, so verify them. Then add the same `SDKROOT = auto; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"; MACOSX_DEPLOYMENT_TARGET = 26.4;` to the **ReTiCAMsgrTests** Debug and Release configs, plus `CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = ReTiCAMsgr/ReTiCAMsgr-macOS.entitlements;` on both app configs.
- Create: `ReTiCAMsgr/ReTiCAMsgr-macOS.entitlements` containing `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.network.server`, `com.apple.security.device.bluetooth`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.personal-information.addressbook` (all true), `com.apple.developer.aps-environment = development`, `com.apple.security.application-groups = [group.co.lithobyte.ReTiCaMsgr]`, and `keychain-access-groups = [$(AppIdentifierPrefix)co.lithobyte.reticulum.identity]`.
- Create: `ReTiCAMsgr/Platform/PlatformImage.swift`
- Create: `ReTiCAMsgr/Platform/PlatformModifiers.swift`
- Create: `ReTiCAMsgr/Platform/Pasteboard.swift`
- Modify: every app file with `import UIKit` or `import MessageUI` (AppDelegate, AttachmentViews, AvatarCropView, AvatarView, BackgroundTask+UIKit, BlockingViews, ChatView, PushPlatform+UIKit, QRCodeImage, ReactionPaletteMenu, SettingsView, PeerInfoView, MessageInfoSheet, DiagnosticsView, QRScannerView) so that each such import is wrapped in `#if canImport(UIKit)` / `#if canImport(MessageUI)`. This is the only change those files get in this task, so the macOS build gets past module resolution and reports per-file errors.
- Test: `ReTiCAMsgrTests/PlatformImageTests.swift`

**Interfaces (Produces, used by Tasks 2–5):**
- `typealias PlatformImage = UIImage` (iOS) / `NSImage` (macOS).
- On macOS only, `extension NSImage`: `convenience init(cgImage: CGImage)` (size from the pixel dimensions), `var cgImage: CGImage? { get }`, `func jpegData(compressionQuality: CGFloat) -> Data?` (through `NSBitmapImageRep`). With these, the existing `UIImage` call sites compile unchanged once retyped to `PlatformImage`. `init?(data:)` and `init?(contentsOfFile:)` already exist on both.
- `extension Image { init(platformImage: PlatformImage) }` → `Image(uiImage:)` / `Image(nsImage:)`.
- `extension View`:
  - `func inlineNavigationTitle() -> some View`: `.navigationBarTitleDisplayMode(.inline)` on iOS, identity on macOS.
  - `func autocapitalization(_ mode: PlatformAutocapitalization) -> some View`, with `enum PlatformAutocapitalization { case never, words }`: `.textInputAutocapitalization` on iOS, identity on macOS.
  - `func platformKeyboard(_ kind: PlatformKeyboard) -> some View`, with `enum PlatformKeyboard { case url, numberPad, asciiCapable }`: `.keyboardType` on iOS, identity on macOS.
  - `func fullScreenCoverOrSheet<Item: Identifiable, C: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View` and `func fullScreenCoverOrSheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View`: `.fullScreenCover` on iOS; on macOS `.sheet` whose content has `.frame(minWidth: 480, minHeight: 480)`.
  - `func insetGroupedListStyle() -> some View`: `.listStyle(.insetGrouped)` on iOS, `.listStyle(.inset)` on macOS.
- `extension ToolbarItemPlacement { static var barLeading: Self; static var barTrailing: Self }`: `.topBarLeading`/`.topBarTrailing` on iOS, `.navigation`/`.primaryAction` on macOS.
- `enum Pasteboard { static func copy(_ string: String) }`: `UIPasteboard.general.string` on iOS; `NSPasteboard.general.clearContents()` + `setString(_:forType: .string)` on macOS.
- `enum SystemSettings { static var url: URL? }`: `UIApplication.openSettingsURLString` on iOS; `x-apple.systempreferences:com.apple.preference.security?Privacy` on macOS. Callers open it with `openURL`.

- [ ] **Step 1: Write the failing tests** in `ReTiCAMsgrTests/PlatformImageTests.swift` (Swift Testing, `@MainActor` struct, matching `QRCodeImageTests.swift`):
  - `cgImageRoundTripKeepsPixelSize`: build a 40×20 solid-red `CGImage` with `CGContext`; `PlatformImage(cgImage:)`; `#expect(image.cgImage?.width == 40)` and `#expect(image.cgImage?.height == 20)`.
  - `jpegDataDecodesBackToSameSize`: same image, `jpegData(compressionQuality: 0.9)` is non-nil; decoding it with `CGImageSourceCreateWithData` gives a 40×20 image.
  - `pasteboardCopyIsReadBack`: `Pasteboard.copy("abc123")`, then read back through `UIPasteboard.general.string` / `NSPasteboard.general.string(forType: .string)`, and `#expect(== "abc123")`.
- [ ] **Step 2: Run on iOS and confirm they fail** (the helpers don't exist yet): `xcodebuild test -project ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/ReTiCAMsgr/dd-t1-ios -only-testing:ReTiCAMsgrTests/PlatformImageTests`. Expected: a compile failure on `PlatformImage`.
- [ ] **Step 3: Implement** the entitlements file, the pbxproj additions, the three `Platform/` files, and the import fences.
- [ ] **Step 4: Run the tests on iOS and confirm they pass**, using the same command.
- [ ] **Step 5: Mutation check (CLAUDE.md).** In one batch: make macOS `cgImage` return nil, make `jpegData` return `Data()`, and make the iOS `Pasteboard.copy` write `string + "x"`. Run on iOS, and confirm the pasteboard test fails; the image tests exercise the macOS code, so re-run them after Task 6 on macOS with the same mutation batch. Revert, then run again and confirm green.
- [ ] **Step 6: Verify the iOS build is green, and verify the macOS build now gets past dependency scanning.** Run the macOS build command: it should report per-file type errors only, with no `unable to resolve module dependency`. Save the error list to `/tmp/ReTiCAMsgr/mac-errors-baseline.txt` (with `-quiet`, xcodebuild output redirected through the Bash tool's output file is fine).
- [ ] **Step 7: Commit** `feat(macos): multiplatform app target, Mac entitlements, platform helpers`. Then create the four sibling worktrees from this commit: `git worktree add -b feat/macos-<task> ../ReTiCAMsgr-macos-<task> feat/macos`, for task in `app`, `images`, `settings`, `chat`.

---

Tasks 2–5 run **in parallel**, one subagent per sibling worktree. Each touches only its listed files. Each one's done-check:
- (a) the iOS build is green;
- (b) the macOS build command shows **no errors in its own files**: filter the log for its file names; errors in other tasks' files are expected until merge;
- (c) commit on its branch.

### Task 2: App lifecycle, push and background (worktree `-app`)

**Files:** `ReTiCAMsgr/ReTiCAMsgrApp.swift`, `ReTiCAMsgr/AppDelegate.swift`, `ReTiCAMsgr/PushPlatform+UIKit.swift`, `ReTiCAMsgr/BackgroundTask+UIKit.swift`, `ReTiCAMsgr/AppRuntime.swift`; Create `ReTiCAMsgr/PushPlatform+AppKit.swift`.

- `ReTiCAMsgrApp`:
  - `@UIApplicationDelegateAdaptor` on iOS, `@NSApplicationDelegateAdaptor(AppDelegate.self)` on macOS.
  - In the `scenePhase` handler, `.background → backgrounded()` stays iOS-only. On macOS `.active → foregrounded()` still runs, which is harmless.
- `AppDelegate`:
  - The class becomes `final class AppDelegate: NSObject, UNUserNotificationCenterDelegate`, keeping `runtime`, `stash`, and both notification-centre methods.
  - The UIKit methods move into `#if os(iOS) extension AppDelegate: UIApplicationDelegate`, with bodies unchanged.
  - Add `#if os(macOS) extension AppDelegate: NSApplicationDelegate` with:
    - `applicationDidFinishLaunching(_:)`, which sets the UNUserNotificationCenter delegate;
    - `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`;
    - `application(_:didFailToRegisterForRemoteNotificationsWithError:)`;
    - `application(_:didReceiveRemoteNotification:)`, which decodes, stashes, then `Task { _ = await runtime.pushWake() }`.
  - The `applicationState == .active` check in `willPresent` becomes a private `isAppActive: Bool`: UIKit `applicationState == .active` / `NSApplication.shared.isActive`.
- Fence `PushPlatform+UIKit.swift` and `BackgroundTask+UIKit.swift` entirely in `#if os(iOS)`.
- `PushPlatform+AppKit.swift` (`#if os(macOS)`): `static let appKit`, with the same `requestAuthorization` body and `NSApplication.shared.registerForRemoteNotifications()` / `unregisterForRemoteNotifications()`.
- In `AppRuntime`, choose `.uiKit` / `.appKit` for `pushPlatform` with `#if`. `backgroundTask = .uiKit` becomes iOS-only; macOS leaves it at `BackgroundTaskClient.liveValue`, which must be set explicitly for the hosted-XCTest reason in the existing comment.

No new tests. This is glue with no logic beyond what iOS already runs. `AppRuntimeTests`/`PushRuntimeTests` must stay green on iOS: run `-only-testing:ReTiCAMsgrTests/AppRuntimeTests -only-testing:ReTiCAMsgrTests/PushRuntimeTests`.

### Task 3: Images (worktree `-images`)

**Files:** `ReTiCAMsgr/AttachmentViews.swift`, `ReTiCAMsgr/AvatarView.swift`, `ReTiCAMsgr/AvatarCropView.swift`, `ReTiCAMsgr/QRCodeImage.swift`, `ReTiCAMsgr/ReactionPaletteMenu.swift`, `ReTiCAMsgrTests/QRCodeImageTests.swift`; Test: `ReTiCAMsgrTests/AvatarCropRenderTests.swift`.

- Replace `UIImage` with `PlatformImage` and `Image(uiImage:)` with `Image(platformImage:)` throughout. `NSCache<NSString, PlatformImage>` works on both.
- `AvatarCropView.render(side:)`:
  - Extract the drawing into `static func renderSquareJPEG(_ image: PlatformImage, crop: CGRect, outputSide: CGFloat) -> Data?` in the same file. `crop` is in image points, origin top-left.
  - iOS keeps the `UIGraphicsImageRenderer` body verbatim.
  - macOS draws `image.cgImage` into an opaque `CGContext` of `outputSide`², scale 1, with y flipped so the top-left semantics match, then `jpegData(compressionQuality: 0.9)`.
- Fence the camera picker struct (the `UIViewControllerRepresentable` at line 144 and its `isAvailable`) in `#if os(iOS)`. Task 4 fences its call site in SettingsView.
- `ReactionPaletteMenu.dimmedEmoji`: on macOS use `renderer.nsImage ?? NSImage()` (NSImage isn't templated by default, so no rendering mode).
- `.inlineNavigationTitle()` for line 52.
- **Tests** (`AvatarCropRenderTests`):
  - `rendersRequestedSquare`: a 200×100 image, left half red and right half blue; `renderSquareJPEG(crop: CGRect(x: 0, y: 0, width: 100, height: 100), outputSide: 512)` decodes to 512×512.
  - `cropTakesTopContent`: a 100×100 image with the top half red and the bottom half blue, crop `(0, 0, 50, 50)`: the centre pixel of the output is red (R > 200, B < 60). This pins the flip.
  - `cropTakesBottomContent`: the same image, crop `(0, 50, 50, 50)`: the centre pixel is blue (B > 200, R < 60).
  - Mutation batch: drop the y-flip on macOS, and on iOS draw at `+crop.minY` instead of `-crop.minY`. Both crop tests must fail on each platform (iOS now; macOS in Task 6).

### Task 4: Settings, contacts and forms (worktree `-settings`)

**Files:** `ReTiCAMsgr/SettingsView.swift`, `ReTiCAMsgr/PeerInfoView.swift`, `ReTiCAMsgr/ContactPicker.swift`, `ReTiCAMsgr/NodeFormView.swift`, `ReTiCAMsgr/GroupViews.swift`, `ReTiCAMsgr/ConversationListView.swift`.

- Replace the modifiers with the Task 1 helpers:
  - `.inlineNavigationTitle()`
  - `.autocapitalization(.never/.words)`
  - `.platformKeyboard(...)`
  - `.fullScreenCoverOrSheet`
  - toolbar `.barLeading`/`.barTrailing`
  - `SystemSettings.url` with `openURL` (in PeerInfoView, `UIApplication.shared.open` becomes `@Environment(\.openURL)`)
  - `UIImage(data:)` becomes `PlatformImage(data:)`
- SettingsView keyboard toolbar: fence `ToolbarItemGroup(placement: .keyboard)` in `#if os(iOS)`.
- SettingsView camera button and `.fullScreenCover(isPresented: $showingCamera)`: fence in `#if os(iOS)`, because the camera picker is iOS-only (Task 3).
- `ContactPicker` on macOS:
  - Add an `NSViewRepresentable` with the same `init(onPick:onCancel:)` that, once in a window, shows `CNContactPicker` relative to its own bounds (`showRelative(to:of:preferredEdge: .maxY)`).
  - `CNContactPickerDelegate.contactPicker(_:didSelect:)` calls `onPick` with `contact.identifier` and the `CNContactFormatter` full name; `contactPickerDidClose` calls `onCancel` unless already picked.
  - The iOS struct stays verbatim under `#if os(iOS)`.
- No new tests: these are modifier swaps. Check that the iOS build is green.

### Task 5: Chat and sheets (worktree `-chat`)

**Files:** `ReTiCAMsgr/ChatView.swift`, `ReTiCAMsgr/MessageInfoSheet.swift`, `ReTiCAMsgr/DiagnosticsView.swift`, `ReTiCAMsgr/EmojiPickerSheet.swift`, `ReTiCAMsgr/AnnounceListView.swift`, `ReTiCAMsgr/RadioPickerView.swift`, `ReTiCAMsgr/AddressView.swift`, `ReTiCAMsgr/QRScannerView.swift`, `ReTiCAMsgr/BlockingViews.swift`, and whichever view presents `QRScannerView` (find with grep; it gets its entry point fenced).

- Modifier swaps as in Task 4:
  - `UIPasteboard.general.string = x` becomes `Pasteboard.copy(x)`
  - `.insetGroupedListStyle()`
  - `.fullScreenCoverOrSheet(item: $viewerTarget)` in ChatView
  - `.barTrailing`
- EmojiPickerSheet: `.searchable` placement `.navigationBarDrawer(displayMode: .always)` on iOS, default placement on macOS.
- QRScannerView: fence the `DataScannerRepresentable` body in `#if os(iOS)`. On macOS, `QRScannerView.isAvailable` (line 24) returns `false`, so existing callers that already gate on it hide the scan entry. Check each caller gates on it, and fence any that don't.
- BlockingViews: fence the `MFMailComposeViewController` wrapper and the `canSendMail` path in `#if canImport(MessageUI)`. On macOS the report goes straight to the existing `mailto:` path (`Self.mailtoURL(draft)`).
- No new tests. Check that the iOS build is green.

---

### Task 6: Integration (sequential, after Tasks 2–5)

- [ ] **Step 1:** Merge `feat/macos-app`, `-images`, `-settings` and `-chat` into `feat/macos` with `git merge --no-ff`, one at a time. The file sets are disjoint, so there should be no conflicts; if one appears, stop and diagnose.
- [ ] **Step 2:** Run the macOS build command and fix every remaining error. Expect stragglers in files no task owned (grep found none, but the compiler is authoritative). Then run the iOS build and make it green.
- [ ] **Step 3:** Run the full app test suite on the iOS simulator; all tests must pass. Then run it on macOS: `xcodebuild test ... -destination platform=macOS`. Tests that need iOS-only state (UIKit pasteboard, the shared keychain entitlement on the hosted test bundle) get `#if os(iOS)` fences, with a comment saying why. Re-run the Task 1 mutation batch on macOS to prove `PlatformImageTests` exercises the NSImage code, then revert and confirm green.
- [ ] **Step 4:** Run `swift test --package-path ReTiCAMsgrCore` (macOS). It must be as green as on main; the known baseline flakes are in memory.
- [ ] **Step 5:** Run a signed launch: build with automatic signing (`-allowProvisioningUpdates`), launch the `.app`, and confirm that:
  - the identity is created or loaded, with no keychain error in the log;
  - the database and push storage open (app group);
  - the default TCP node connects.

  Take a screenshot. If provisioning fails (Mac not registered, push capability missing on the App ID), stop and report it to the user; that's theirs to fix in the developer portal.
- [ ] **Step 6:** Commit the fixes, then write a short memory note (feature, branch, what's owed). Don't merge to main: that's the user's call.
