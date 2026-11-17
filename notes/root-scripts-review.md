# Root scripts review (2026-11-17)

Scope: packaging/venera-watch.sh, helper/Venera/main.m, install.sh, uninstall.sh, status.sh, sysvol.sh, make-pkg.sh
(pkg scripts). Checked with `bash -n` / `zsh -n`; shellcheck is not installed. Not run as root (no VM touched).

## Fixed

1. venera-watch.sh `pool_caches` (HIGH, local root). It found `*local.homelab.VirtioGPUMetal/spirv` folders under
   /private/var/folders and ~/Library/Containers (user-writable, user-plantable), then as root copied files out of them
   and `cp "$f" "$d/"` into them. A dangling symlink named like a hash, pointing at e.g. /etc/sudoers.d/x, made root
   create that file with pool content, which the user controls (a hash-named file the user plants is copied into the
   pool first): arbitrary root file write with chosen content. A swapped folder or file symlink also gave an arbitrary
   write (hash name) or a read-disclosure (a hard link or symlink to a root-only file got copied into the 644 pool).
   Fix: every read and write inside such a folder is done as the folder's owner (`sudo -u "#UID"`); only plain files
   with a hash name, owned by the owner, one link, under 16 MB, are pooled (read as the owner into a root-made temp
   file, then moved). Root-owned folders are used only under /private/var/folders/zz.
2. install.sh, uninstall.sh: kmutil log at fixed /tmp/venera-kmutil.log (MEDIUM, arbitrary file clobber via a planted
   symlink, sticky /tmp does not stop it on macOS). Now `mktemp /private/var/run/...`.
3. uninstall.sh: `rm -rf` as root inside user cache folders (MEDIUM, delete race: swap a subfolder for a link mid-delete).
   Now the owner runs the rm (`sudo -u "#UID"`); root-owned only under var/folders/zz.
4. venera-watch.sh `dialog` (LOW): the AppleScript text escaped quotes but not backslashes (a `\"` in sysvol.sh's output
   could end the string). It runs as the console user, so no root gain; backslashes are now escaped first.
5. venera-watch.sh `ask_app` (LOW): reading the user-writable answer could catch the truncate-before-write moment, and
   read an unbounded file. Now reads at most two lines, 64 bytes each, and waits until the answer line is non-empty.
6. make-pkg.sh core script (LOW/hardening): root runs `$V/release/install.sh`; it now chowns `release` to root:wheel,
   go-w first. install.sh: `$V` and the kept-copy folder chown root:wheel / 755 (also guards a restrictive umask);
   Venera.app gets `chmod -R go-w`.

## Judged safe

- `ask_app` paths: `$V/ask` is under a root-owned folder, made fresh (`rm -rf`, `mkdir`) each time; only `answer` is
  user-owned and the user cannot unlink, rename, symlink or hard-link anything in the folder. root's chown/chmod/rm
  there cannot be redirected. The answer is compared with `[ = ]` against the offered buttons only; nothing is eval'd
  or interpolated; the wait is bounded (1800 x 2 s). Buttons and text come from literals in the watcher.
- main.m: only reads root's files and writes `answer`; non-atomic write is required (the file is the user's, the folder
  is root's, a rename would fail). It accepts only buttons it was offered. Nothing it writes is trusted beyond that.
- install.sh/uninstall.sh `rm -rf` targets are constants or `$OC_ROOT` (verified non-empty before use); no `$HOME`
  or user files used as root; `launchctl bootstrap gui/UID` loads a root-owned plist. uninstall removes only what
  install makes (plus the OpenCore entries it names). status.sh writes nothing. sysvol.sh works on root-owned paths.

## Residual (not fixable in a script)

- Any process running as the console user can answer the watcher's question without the person seeing it
  ("Reinstall" runs sysvol.sh with root's own kept copy; "Restart" reboots). No privilege gain, but no consent either.
- The shader pool is shared: a user's process can plant an entry that WindowServer later reads (names are a hash of
  the input, so the content can't be verified). Fine on a one-user VM; a trust boundary on a multi-user one.
