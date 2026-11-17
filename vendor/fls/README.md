# Embedded fls

This directory contains the eight Glosso modules from the neighboring `fls`
project, version 0.1.0, snapshotted on 2026-11-15. Copyright 2026 Sungbae Jeong.
The upstream MIT license is retained in [LICENSE](LICENSE).

Lush compiles these sources into its executable. An installed `fls` executable
or a sibling checkout is not required. The command-line listing, long/grid/tree
renderers, colors, Nerd Font icons, Git status, browser, and airplane animation
come from these sources. `src/fls.glo` in Lush adapts their entry points and
exposes file records using the same option parser, filters, and sorting.
The renderer and record adapter share Lush's `directory_size.glo` walker,
which counts entries during interactive `--total-size` scans.

The snapshot has adaptations for a persistent shell process:

- `cli.glo`: reset the global output builder after a listing, clearing its
  freed buffer header before the next invocation; transfer owned absolute
  path strings without making or leaking extra copies.
- `theme.glo`: own and release color-pattern text, release environment query
  results, and reset overrides so changes to `LS_COLORS`/`EZA_COLORS` take effect.
- `git.glo`: expose a cleanup function for repository and negative lookup
  caches, so each invocation sees fresh Git status; allocate a fallback path
  only when canonicalization fails.
- `util.glo`: expose cleanup for identity/group/timezone caches and refresh
  cached time between invocations; allocate fallback identity text only when
  lookup fails; use native Windows path helpers so canonical paths retain
  valid separators when joining entries or navigating to parent directories.
- `tui.glo`: query owned environment values through a helper that allocates
  fallback text only on failure; hide the cursor before painting and position
  the input caret before showing it, following rne's terminal loop; use the
  native `lush.open` handler for the default file opener on Windows. Longer
  copies and deletions display progress in the browser's status row.
- `lol.glo`: keep the cursor hidden throughout each animation frame and restore
  it on exit. Both interactive views use Lush's `src/screen.glo` helper, which
  mirrors cursor visibility to ConPTY hosts in the VT output stream.

The adapter supplies an isolated scratch allocator. Upstream's existing
per-directory and per-frame resets clear that arena while preserving the
shell's temporary strings. Cleanup and restoration run on every return path.

Original source SHA-256 digests before these adaptations:

| File | SHA-256 |
| --- | --- |
| cli.glo | CD599C33A3FD097F9EEC9184497BC158DD5CAE155C9C6050F515C9759362150F |
| entry.glo | D47B3935E294D5AE7DD5FD294818007AFECBEFCC0D1D74F7E16AF41CDDB872B5 |
| git.glo | AD6B05BF75279845611538E3654069ABB32E9B8059A8DA382A8BE659B30349EE |
| lol.glo | 8639356E5DA7718D54FDED14C881B9B1D34B7FFC83A31BEAB3E8578ED8B4DA80 |
| options.glo | CF266A10969D1860DA4FA8970553431A06C710FB21304567E8A6620F8836B1D0 |
| theme.glo | C1954F4925804A1E2E8258DA81F4640CBA4C3C73225DDCF1650044C783352B6F |
| tui.glo | 0309F3D4B5EC79E014C3CCB4410FD57F3761F911CA10B8DA787AF68C9F21621D |
| util.glo | DB2D5EA0D487E11686271CA5488BA7AD3540387D6036526CB90CAAC375F052F2 |
