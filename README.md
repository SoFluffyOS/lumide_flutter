# lumide_flutter

[![pub package](https://img.shields.io/pub/v/lumide_flutter.svg)](https://pub.dev/packages/lumide_flutter) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Powered by SoFluffy](https://img.shields.io/badge/Powered%20by-SoFluffy-orange)](https://sofluffy.io)

The official Flutter extension for [Lumide IDE](https://lumide.dev).

`lumide_flutter` turns Lumide into a fully-fledged Flutter development environment. It provides project management, device handling, debugging tools, and real-time log streaming.

## Features

### 🚀 Project Management
- **Create Projects**: Easily start new Flutter projects (`flutter.create`).
- **Dependency Management**: Run `pub get` for single projects or the entire workspace in parallel.
- **Environment Checks**: Built-in `flutter doctor` integration to diagnose issues.

### 📱 Device Manager
- **Dynamic Detection**: Automatically detects connected devices (iOS, Android, Web, Desktop).
- **Quick Switching**: Switch active devices instantly via the Status Bar or Command Palette.
- **Platform Icons**: Visual indicators for device types (Mobile, Web, Monitor).

### ⚡ Run & Debug
- **Debug Sessions**: Launch Flutter under the debugger from the toolbar Debug button or the `Flutter: Debug` command.
- **Breakpoints**: Set breakpoints in the editor gutter and inspect verified breakpoint state in Lumide’s debug panel.
- **Stack & Variables**: Inspect stack frames, scopes, and expandable variables directly in the debug panel when execution pauses.
- **Stepping Controls**: Continue, Pause, Step Over, Step Into, Step Out, and Stop are exposed through the debug toolbar.
- **Exception Filters**: Switch between ignored, uncaught, and all exceptions from the debug panel.
- **Hot Reload**: Trigger hot reload on save (configurable), via the toolbar, or with `Cmd + \`.
- **Hot Restart**: Full application restart with `Cmd + Shift + \` or a single click on the toolbar.
- **DevTools**: Open [Dart DevTools](https://flutter.dev/devtools) directly within a Lumide pane or in your external browser.
- **Debug Output**: In debug mode, Flutter logs are shown inside the debug panel’s Output section so logs and paused-state inspection stay together.
- **Run Output**: In run mode, view colored, real-time logs in the **Flutter** output channel. Separate **Build Output** keeps things clean.

### 🛠 Editor Integration
- **Status Bar**: Shows the active Flutter SDK version. Click to access the *Flutter Tools* menu.
- **Toolbar**: Context-aware controls (Run, Stop, Reload, Restart) appear when a Flutter project is active.
- **Debug Navigation**: When a breakpoint is hit, Lumide jumps to the stopped source location and lets you navigate by stack frame or breakpoint entry.
- **Dart snippets**: Short Flutter prefixes in `.dart` files (`stless`, `listb`, `streamb`, …).
- **Import assist**: Heuristically adds/removes managed Flutter imports on save (or via **Flutter: Ensure Imports**), powered by [`lumide_import_assist`](https://pub.dev/packages/lumide_import_assist). Text snippets do not go through Dart completion, so they do not trigger LSP auto-import — save the file or run the command after inserting a snippet.

### Snippets

| Prefix | Description |
|---|---|
| `stless` / `stful` / `stanim` | Stateless / Stateful / animated Stateful widget |
| `matapp` / `cupapp` | `MaterialApp` / `CupertinoApp` starter |
| `inhw` | `InheritedWidget` |
| `fbuild` / `initS` / `dis` / `didUpdate` / `didChange` | Build + State lifecycle |
| `listb` / `lists` | `ListView.builder` / `separated` |
| `gridb` / `gridc` / `gride` | `GridView` constructors |
| `csv` / `scsv` | `CustomScrollView` / `SingleChildScrollView` |
| `streamb` / `futureb` / `animb` / `sbuilder` / `layoutb` / `orib` / `vlb` / `tweenb` | Common builders |
| `painter` / `clipper` | `CustomPainter` / `CustomClipper` |
| `impm` / `impc` / `impt` | Material / Cupertino / flutter_test imports |
| `ftw` / `dprint` | `testWidgets` / `debugPrint` |

## Commands

Access these via the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`):

| Command ID | Title | Description |
|---|---|---|
| `flutter.doctor` | **Flutter: Doctor** | Run diagnostics |
| `flutter.pub.get` | **Flutter: Pub Get** | Get packages for current project |
| `flutter.clean` | **Flutter: Clean** | Delete build/ directory |
| `flutter.create` | **Flutter: New Project** | Create a basic Flutter app |
| `flutter.selectDevice` | **Flutter: Select Device** | Choose run target |
| `flutter.run` | **Flutter: Run** | Start app on selected device |
| `flutter.debug` | **Flutter: Debug** | Start app on selected device with debugger attached |
| `flutter.hotReload` | **Flutter: Hot Reload** (`Cmd+\`) | Update code changes (JIT) |
| `flutter.hotRestart` | **Flutter: Hot Restart** (`Cmd+Shift+\`) | Restart app state |
| `flutter.stop` | **Flutter: Stop App** | Terminate process |
| `flutter.openDevToolsWebview` | **Flutter: Open DevTools** | Open in split pane |
| `flutter.ensureImports` | **Flutter: Ensure Imports** | Sync managed Flutter imports for the active file |

## Configuration

Customize behavior in your `.lumide/settings.json` or Workspace Settings:

| Key | Default | Description |
|---|---|---|
| `flutter.hotReloadOnSave` | `true` | Trigger hot reload when saving `.dart` files |
| `flutter.clearLogOnHotRestart` | `true` | Clear the output channel when restarting |
| `flutter.logEntryLimit` | `5000` | Max lines in the Flutter output channel |
| `flutter.autoImportOnSave` | `true` | Sync Flutter imports when saving `.dart` files |
| `flutter.removeUnusedImportsOnSave` | `true` | Also remove unused managed Flutter imports on save |

## Requirements

- **Flutter SDK**: Must be installed and available in your system `PATH`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ by [SoFluffy](https://sofluffy.io).

## Happy Coding 🦊
