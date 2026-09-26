# Run-code probe, Claude Code 2.1.280

Captured with a probe script that launches the CLI the way the
app launches a work turn (default mode, sandbox on, `autoAllowBashIfSandboxed` off,
questions over `--permission-prompt-tool stdio`, its own process group). The probe
allowed a Bash question whose command ran python and was not an install,
as an approved run card would; everything else it refused.
Paths are scrubbed to `/private/tmp/run-code-probe.noindex`.

`bash-asks.json` holds every Bash question the CLI asked, per run. The shapes that
matter to the run card:

- `python3 Outbox/list_by_date.py .` and `python3 Outbox/list_files_by_date.py`: the
  plain run, a relative script path, the working folder as the shell's folder.
- `cd "<bot folder>" && python3 Outbox/bar_chart.py && ls -l Outbox`: a `cd` into the
  bot's own folder first, a read-only command after.
- `python3 -c "…" 2>&1; echo "---"; ls` and `cd "<bot folder>" && python3 - <<'EOF' …`:
  inline code, never a script file.
- `python3 -m venv "$TMPDIR/venv" 2>&1 | tail -5 && "$TMPDIR/venv/bin/pip" install --quiet requests 2>&1 | tail -20`
  and `python3 -m pip install --user requests 2>&1 | tail -20`: the two ways it asked to
  install a package; neither starts with `pip`.
- `cd "<bot folder>/Outbox" && nohup python3 count.py > /dev/null 2>&1 &` followed, after a
  newline, by `echo "pid=$!"; sleep 3; cat …`: a background run, asked for in the prompt.
  A newline separates commands.

**Stop.** In run `d-stop` the probe stopped the turn as the app's Stop does,
`kill(-cliPID, SIGKILL)`, twenty seconds into `python3 Outbox/count_to_300.py`. The CLI
died; the script did not. `ps` afterwards: the CLI's shell `/bin/zsh -c … eval 'python3
Outbox/count_to_300.py'` was its own group's leader (pgid = its pid) and had been
reparented to launchd (ppid 1), with python in that group. The CLI starts every Bash
command's shell in a new process group, so the app's group kill never reaches it.
Run `g-stop-reap` is the same turn with the fix tried in the probe: the CLI's
descendants listed while it is alive, a group leader among them killed by its group,
twice, then the CLI's group. It found two descendants before,
none after.

**Background.** In run `h-stop-bg` the turn ended normally and `count.py` kept running
(pid 94340, group 94338, whose leader was already gone, ppid 1). No tree walk at the
turn's end can find it. Its environment still carried the CLI's: every variable the
launch set reached the script, so a per-turn marker in the CLI's environment names
it.
