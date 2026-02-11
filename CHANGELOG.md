## 1.0.0 (2026-02-15)

### 🚀 New Features

*   **Project Management**:
    *   Create New Flutter projects (`flutter.create`).
    *   Initialize projects with `pub get` (Parallel execution supported).
    *   Clean build artifacts with `flutter clean`.
    *   Run `flutter doctor` to check environment health.

*   **Running & Debugging**:
    *   Full Run/Stop support (`F5` / `Shift+F5`).
    *   **Hot Reload** on save or via toolbar.
    *   **Hot Restart** support.
    *   View real-time logs in the **Flutter** output channel.
    *   Separate **Build Output** channel.

*   **Device Management**:
    *   View currently selected device in the Status Bar.
    *   Switch devices via Quick Pick menu (`flutter.device`).
    *   Support for Web, Mobile, and Desktop devices with platform-specific icons.

*   **DevTools Integration**:
    *   Open Dart DevTools in an embedded **Webview Panel**.
    *   Option to open DevTools in external browser.

*   **User Experience**:
    *   **Status Bar**: Quick access to Flutter Tools menu.
    *   **Toolbar**: Dynamic controls based on run state.
    *   **Notifications**: Batched error reporting for bulk operations.
