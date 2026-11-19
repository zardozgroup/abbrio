# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's private vulnerability reporting: open the
[Security tab](https://github.com/zardozgroup/abbrio/security) of this repository and choose
**Report a vulnerability**. Don't open a public issue, pull request or discussion for a security problem.

A useful report includes:

- the Abbrio version (About Abbrio) and build, the macOS version and the Espanso version (`espanso --version`)
- what an attacker can do and what they need to do it
- steps to reproduce, with a minimal snippet file, package or config if one is involved
- diagnostics such as logs, crash reports or screenshots, with personal data redacted

Your snippets and Espanso config can hold passwords, addresses and other private text. Remove or replace
anything personal before you attach files or logs, and never send real credentials.

## What gets fixed

Fixes are made for the latest release and for the current development branch (`main`). Older releases are
not patched; the fix comes in the next release.

This is a volunteer project, and no response or fix times are promised. Reports are read and handled as
time allows. Please keep the details private until a fix has been released.

## Things to know about how Abbrio works

These are part of the design rather than vulnerabilities, but they matter when you judge a risk.

### Snippets and packages can run commands

Espanso snippets can contain shell commands and scripts (`type: shell` and `type: script` variables). They
run with your user account's permissions whenever the snippet expands, and they can read and change your
files or access the network. Packages from the Espanso Hub or from a git repository can contain such
snippets too.

Abbrio does not sandbox them. In the Script and Shell Command sheets, **Test** runs the code on your Mac
right away, with the same permissions. Only install packages and import snippets you have read and trust,
and read a package's triggers and README before you install it.

### Package checksums show integrity, not authorship

When Abbrio previews a package from the Espanso Hub, it downloads the archive and checks it against the
SHA256 checksum published for it. The checksum comes from the same place as the archive, the Hub's GitHub
releases. A match shows that the archive arrived complete and unchanged. It does not show who made the
package or that its contents are safe: anyone able to replace the archive could replace the checksum as
well. Packages installed from a git repository have no checksum at all.

### Quick Search and Accessibility

Quick Search needs the Accessibility permission because it pastes into other apps. It is the only part of
Abbrio that sends keystrokes, and it restores your clipboard afterwards.
