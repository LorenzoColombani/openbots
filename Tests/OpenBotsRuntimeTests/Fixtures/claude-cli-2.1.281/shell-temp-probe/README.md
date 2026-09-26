# Shell temporary folder and zsh startup files, Claude Code 2.1.281

Captured with a probe script in the work shape: the app's
protected paths as the sandbox's denyRead and denyWrite, the app's work PATH, a clean
environment (`env -i`), a sonnet model and every Bash question allowed as an approved card
would. Each file lists the commands the bot ran and what came back; `$HOME` replaces the
home folder. Guarded by the tests in `ClaudeTextShellTemporaryDirectoryTests.swift`.

- `long-folder-2.1.281.txt`: `CLAUDE_CODE_TMPDIR` where the app used to put it,
  `$TMPDIR/OpenBotsNext-Shell.noindex/<uuid>`. The CLI logs that `<folder>/claude-501` is
  123 bytes, too long for its Unix sockets, and gives commands `/tmp/claude-501`, the folder
  every Claude Code session of this user shares; the bot's shell wrote there. The shell's
  PATH also carries what the user's own zsh startup files add, through the CLI's zsh snapshot.
  Swift runs.
- `long-folder-2.1.280.txt`: the same launch on 2.1.280. The long folder itself is the
  shell's TMPDIR and the sandbox refuses writes in it: `touch` gets "Operation not
  permitted" and `swift` "error: permissionDenied", the failure the run-code probe met.
- `short-folder-2.1.281.txt`: `/tmp/obn-<8 hex>`. TMPDIR is `<folder>/claude-501`, a write
  there works, a write in the shared `/tmp/claude-501` is refused, Swift runs.
- `short-folder-2.1.280.txt`: on 2.1.280 the short folder is still the shell's TMPDIR and
  still refused, so Swift fails there. The app runs the newest CLI installed.
- `short-folder-no-zsh-files-2.1.281.txt`: the short folder plus `ZDOTDIR=/var/empty`. PATH
  is the app's alone; Swift, Python 3, Node.js and uv all answer.
- `final-folder-2.1.281.txt`: what the app now uses, `/tmp/obn-<8 hex>.noindex` with
  `ZDOTDIR=/var/empty`: no fallback
  warning in the debug log, TMPDIR `<folder>/claude-501` and writable, the app's PATH, Swift runs.

The limit is the CLI's own: `<folder>/claude-<uid>` at most 44 bytes (`r6n=44` in the
2.1.281 binary). `/tmp/obn-<8 hex>.noindex` is 25 bytes.
