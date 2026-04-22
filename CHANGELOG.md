## 1.5.0 (2026-04-22)

_This release requires Lumide version >= 0.2.0._

### 🚀 New Features

* **Debugging support**: Now you can debug your Flutter apps by pressing Debug icon in the toolbar or launch `Flutter: Debug` command.

### ⬆️ Upgrade lumide_api
* Bump `lumide_api` dependency to `1.2.0` to support debugging.

## 1.4.1+1 (2026-03-29)

### ⬆️ Upgrade lumide_api
* Bump `lumide_api` dependency to `1.1.0`.

### 🏷️ Metadata
* Add `lumide-plugin` topics metadata for better Marketplace discovery.

## 1.4.0 (2026-03-11)

### 🚀 New Features

*   **Keyboard Shortcuts**: Added `Cmd + \` for Hot Reload and `Cmd + Shift + \` for Hot Restart.
*   **Device Icons**: Fixed an issue where all devices showed a smartphone icon; now correctly displays icons for Web and Desktop targets.

## 1.3.0 (2026-03-03)

### 🚀 New Features

*   **Flutter Daemon Integration**: Utilize the Flutter Daemon to serve DevTools, removing manual webview fallbacks.
*   **Reactive Device List**: Listen to device connections and disconnections via the daemon instead of manually polling or refreshing.

### 🐞 Bug Fixes

*   Prevent log truncation of multiline or extensive outputs coming from `developer.log`.
*   Correct the Open DevTools menu icon.

## 1.2.0 (2026-02-28)

### 🚀 New Features

*   **Target Picker UI**:
    *   Dynamically scan `**/main.dart` entry points across monorepos and inject them directly into a top-bar Quick Pick interface.
    *   Target paths are processed seamlessly into `flutter run --machine -d <device> -t <relative-lib/main.dart>`.
    *   Automatically resolves the parent package directory and switches `workingDirectory` context to handle deeply nested plugins properly.
    *   Support manual override inputs to inject custom entry points.
*   **Monorepo Support**:
    *   Enforce Workspace rules to prevent unbounded SDK scoping errors on nested monorepo dependencies.
*   **Under The Hood**:
    *   Migrate `lumide_flutter` onto `lumide_api` `v0.9.0` supporting rich `tooltip` item payloads.

## 1.1.1 (2026-02-19)

### 🐞 Bug Fixes

*   Handle incorrect assets path mapping when running from a prebuilt executable.

### 🧹 Refactors

*   Remove redundant version field from the plugin manifest.

## 1.1.0 (2026-02-16)

### 🚀 New Features

*   Add `lumide_flutter` to executables.

## 1.0.0 (2026-02-15)

### 🚀 New Features

*   **Project Management**:
    *   Initialize projects with `pub get` (Parallel execution supported).
    *   Clean build artifacts with `flutter clean`.
    *   Run `flutter doctor` to check environment health.

*   **Running & Debugging**:
    *   **Hot Reload** on save or via toolbar.
    *   **Hot Restart** support.
    *   View real-time logs in the **Flutter** output channel.
    *   Separate **Build Output** channel.

*   **Device Management**:
    *   View currently selected device in the Status Bar.
    *   Switch devices via Quick Pick menu (`flutter.device`).

*   **DevTools Integration**:
    *   Open Dart DevTools in an embedded **Webview Panel**.
    *   Option to open DevTools in external browser.

*   **User Experience**:
    *   **Status Bar**: Quick access to Flutter Tools menu.
    *   **Toolbar**: Dynamic controls based on run state.
    *   **Notifications**: Batched error reporting for bulk operations.
