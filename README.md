# lumide_flutter

[![pub package](https://img.shields.io/pub/v/lumide_flutter.svg)](https://pub.dev/packages/lumide_flutter) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Powered by SoFluffy](https://img.shields.io/badge/Powered%20by-SoFluffy-orange)](https://sofluffy.io)

The official Flutter extension for [Lumide IDE](https://lumide.dev).

## Highlights

- Run, debug, attach, hot reload, and hot restart Flutter apps.
- Launch and switch devices, including stopped Android emulators and iOS Simulator.
- Set targets, flavors, build modes, and launch configurations.
- Use breakpoints, stepping, stack frames, scopes, variables, and evaluation.
- Open focused DevTools panes: Inspector, Performance, CPU Profiler, Memory, Network, and Logging.
- Click a widget in the running app and jump to its Flutter source.
- Toggle the performance overlay from the command palette.
- Run `flutter doctor`, `pub get`, `clean`, and create new projects.
- Select Flutter SDKs from PATH, FVM, Puro, or Lumide’s SDK manager.

## Commands

Use the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`).

| Command | Purpose |
| --- | --- |
| `flutter.run` / `flutter.debug` / `flutter.attach` | Start or attach to an app |
| `flutter.selectDevice` | Choose a device or launch an AVD |
| `flutter.selectTarget` | Choose the Dart entry point |
| `flutter.hotReload` / `flutter.hotRestart` | Apply code changes or reset state |
| `flutter.devtools.<page>` | Open one DevTools page |
| `flutter.toggleWidgetInspector` | Click a widget and open its source |
| `flutter.togglePerformanceOverlay` | Toggle the runtime overlay |
| `flutter.doctor` / `flutter.pub.get` / `flutter.clean` | Run Flutter tools |

Hot reload on save is enabled by default. Configure it with `flutter.hotReloadOnSave`.

## SDKs

Use **SDKs: Manage SDKs** to select or install Flutter. PATH, FVM, and Puro installations are also detected.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ by [SoFluffy](https://sofluffy.io).

## Happy Coding 🦊
