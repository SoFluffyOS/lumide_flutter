# lumide_flutter

[![pub package](https://img.shields.io/pub/v/lumide_flutter.svg)](https://pub.dev/packages/lumide_flutter) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Powered by SoFluffy](https://img.shields.io/badge/Powered%20by-SoFluffy-orange)](https://sofluffy.io)

The official Flutter extension for [Lumide IDE](https://lumide.dev).

## Highlights

- Run, debug, attach, hot reload, and hot restart Flutter apps.
- Launch and switch devices, including stopped Android emulators and iOS Simulator.
- Set targets, flavors, build modes, and launch configurations.
- Use breakpoints, conditions, logpoints, stepping, stack frames, scopes, variables, and evaluation.
- Run tests, single tests, or groups and see results in the Tests pane.
- Open focused DevTools panes: Inspector, Performance, CPU Profiler, Memory, Network, and Logging.
- Click a widget in the running app and jump to its Flutter source.
- Toggle the performance overlay from the command palette.
- Run `flutter doctor`, `pub get`, `pub upgrade`, `pub outdated`, `clean`, `build_runner`, `gen-l10n`, and create new projects.
- Select Flutter SDKs from PATH, FVM, Puro, or Lumide’s SDK manager.

## Commands

Use the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`).

| Command | Purpose |
| --- | --- |
| `flutter.run` / `flutter.debug` / `flutter.attach` | Start or attach to an app |
| `flutter.selectDevice` | Choose a device or launch an AVD |
| `flutter.selectTarget` | Choose the Dart entry point |
| `flutter.hotReload` / `flutter.hotRestart` | Apply code changes or reset state |
| `flutter.test` / `flutter.testFile` / `flutter.stopTests` | Run all tests, the current file's tests, or stop |
| `flutter.debugTestFile` | Debug the current file's tests |
| `flutter.testWithCoverage` | Run tests and show line coverage |
| `flutter.devtools.<page>` | Open one DevTools page |
| `flutter.toggleWidgetInspector` | Click a widget and open its source |
| `flutter.togglePerformanceOverlay` | Toggle the runtime overlay |
| `flutter.doctor` / `flutter.pub.get` / `flutter.clean` | Run Flutter tools |
| `flutter.pub.upgrade` / `flutter.pub.outdated` | Manage dependencies |
| `flutter.buildRunner.build` / `flutter.genL10n` | Generate code and localizations |

Hot reload on save is enabled by default. Configure it with `flutter.hotReloadOnSave`.

Saving a `pubspec.yaml` runs `pub get` for that package. Configure it with `flutter.pubGetOnPubspecSave`.

## Tests

Run all tests, a file, or a folder from the Command Palette or the file tree. Results show in Lumide's Tests pane, and each run's output goes to its own **Flutter Tests** output channel.

Click **Run** above a `test`, `testWidgets`, or `group` to run just that one. In the Tests pane, rerun the whole run, only failed tests, or any suite, group, or test. Different tests run side by side, each in its own Tests pane, and running tests that are still running asks to stop them first.

Click **Debug** above a test, or the debug button on a Tests pane row, to stop at breakpoints. Debugging runs one test file at a time, and not while an app is running.

Run **Flutter: Run Tests with Coverage**, or right-click a test folder, to shade covered and uncovered lines in the editor. Requires Lumide 0.24.0 and later.

## Logpoints

Add a log message to a breakpoint in the Breakpoints panel. `{expression}` placeholders are evaluated in the paused frame, printed to the output, and the app keeps running. Requires Lumide 0.23.0 and later.

## SDKs

Use **SDKs: Manage SDKs** to select or install Flutter. PATH, FVM, and Puro installations are also detected.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ by [SoFluffy](https://sofluffy.io).

## Happy Coding 🦊
