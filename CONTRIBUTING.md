# Contributing

Issues and pull requests are welcome. For anything security-shaped, read
[SECURITY.md](SECURITY.md) first and report it privately.

## Build and test

You need what [docs/INSTALL.md](docs/INSTALL.md) lists (Apple Silicon, Xcode 16.3+).

```sh
Scripts/build-preview.sh                       # the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/swiftpm-public.sh test --no-parallel --scratch-path .build.noindex/gate
```

- **Run the suite serially** (`--no-parallel`), as CI does. A family of tests starts
  real child processes against wall-clock deadlines and is honest about them; under
  parallel load they miss them.
- **The tests never call Claude.** Claude Code's wire format is covered by recorded
  runs under `Tests/OpenBotsRuntimeTests/Fixtures/claude-cli-<version>/`, replayed
  in the suite. When a Claude Code update changes that format, add a new recording
  beside the old ones rather than editing them.
- **Adding a Swift file?** The Xcode project is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). Run `xcodegen generate` after
  adding a file, or the app build cannot see it while the SwiftPM suite stays green.
- **Keep it building on Swift 6.1.** CI builds with Xcode 16.4 on macOS 15 as well as
  a newer Xcode on macOS 26. Newer compilers accept long literal expressions and
  some `Sendable` crossings that Swift 6.1 refuses, so a green local build on a
  newer Xcode is not the whole check.
- `python3 Scripts/public-gate.py .` checks that no machine path, secret or personal
  detail slipped into the tree. CI runs it on every push.

## Design rules the code keeps

- Nothing a bot does beyond chat happens without a switch you turned on for that
  bot, and anything consequential waits on a card that shows exactly what will
  happen.
- A saved plan or an approval is never shown as something that already happened.
- Text from outside (mail, messages, web pages, tool output) is untrusted and is
  marked as such before a bot reads it.

## License

By contributing you agree that your contribution is released under the
[MIT License](LICENSE).
