# Simulator demo mode

Generate the project with `xcodegen generate`, build the CanopyMobile scheme in
Debug for an iOS Simulator, then launch with the `--demo` argument. In Xcode,
add this argument under Scheme > Run > Arguments Passed On Launch.

The demo contains two Macs and four sessions. Open a session or History to
review sample notifications, try permission decisions, answer single- and multi-select questions, and send local replies.
Settings uses an in-memory URL and secret. Demo mode skips APNs registration,
relay connections, Keychain writes, and shared-history writes. Relaunch to reset
sample messages and decisions. The flag is ignored on devices and release builds.

For a booted simulator with the app installed:

```sh
xcrun simctl launch booted sh.saqoo.canopy-app --demo
```
