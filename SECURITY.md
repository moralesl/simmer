# Security

simmer asks for one privileged capability and touches `/etc/sudoers.d`, so this page states exactly what it asks for, what it deliberately does not defend against, and how to report something.

## Reporting

Open a [private security advisory](https://github.com/moralesl/simmer/security/advisories/new) on the repository.
If that is not available to you, open a normal issue saying only that you have a security report and how to reach you — no details in the issue.

Expect a first response within a week. simmer is one person's tool, not a funded project: there is no bounty, and there is no pretence of a 24-hour rotation.

## What simmer asks for, exactly

One sudoers rule, scoped to two invocations of one binary and nothing else:

```
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

- No wildcards, no other `pmset` subcommand, no other executable.
  A unit test asserts the exact string, so widening it cannot happen quietly.
- It lands in `/etc/sudoers.d/simmer`, root-owned, mode 0440, and is validated with `visudo -c` **before** it is installed — a malformed file in `/etc/sudoers.d` can break `sudo` entirely.
- **simmer never escalates its own privileges.** It composes the command, displays it in full, and a human runs it in their own shell.
  There is no `osascript … with administrator privileges` path, and a test asserts its absence.
- The rule is why the background guard can hand the switch back while nobody is at the keyboard.
  That is the entire reason it exists.

Removing it is one command: `sudo rm /etc/sudoers.d/simmer`.
`make uninstall` deliberately does not do it for you, because it needs root and because simmer only ever removes what simmer wrote.

## The install path

The documented installation compiles from source on your machine (`bootstrap.sh`), which is also why the resulting app runs without a Gatekeeper warning: macOS attaches quarantine to browser-style downloads, not to `git clone`.
Two consequences worth knowing:

- Piping a script from `curl` into `bash` means trusting this repository at the moment you run it.
  The script is short and does nothing before its final line; pin a release with `SIMMER_REF=v0.2.0` rather than tracking the default branch if that matters to you, and read it first — that is what the URL is for.
- The bundle is **ad-hoc signed**.
  It has no stable code identity across rebuilds and no Apple Developer certificate, on purpose (`docs/FAQ.md`).

## The one thing simmer sends

`simmer update` — and `Simmer.app` once a day — makes one `HEAD` request to `https://github.com/moralesl/simmer/releases/latest` and reads the tag out of the redirect.
That is the whole network surface.

- **What goes out:** the request line and a `simmer/<version>` User-Agent.
  No identifier, no hostname, no machine detail, no claim, no reason, no telemetry — not now and not later.
- **What comes back is a version string**, and the only thing done with it is a comparison against the compiled-in one.
  Nothing is downloaded, and nothing is executed: simmer prints the command that would update it and stops.
- **Turning it off:** the checkbox in the setup window, or `SIMMER_NO_UPDATE_CHECK=1`.
  That stops the app's background check; `simmer update`, typed by someone asking, still asks.
- **`--cached`** answers from the last check and never opens a socket, which is what `doctor`, the menu bar and the Raycast list use — so the surfaces you did not ask cannot make a request on your behalf.

## What is not a vulnerability

- **Human primacy is not a security boundary.** A human can release any claim and only a human can move the cap — enforced against *honest* actors.
  Nothing stops a process from passing `--owner terminal` or setting `SIMMER_HUMAN=1`, and on a single-user Mac nothing could.
  It exists so an agent following the protocol cannot take a person's awake time away by accident, which is the failure that actually happens.
  Reports that a local process can impersonate a human are correct and already documented (`docs/CONTRACTS.md` § the claims ledger).
- **State is a user-owned directory.** `$XDG_STATE_HOME/simmer/` is readable and writable by the user who owns it, like the rest of their home directory.
  Another process running as that user can edit claims; it can also just call `simmer`.
- **Keeping a Mac awake with the lid closed is the feature.** That it can flatten a battery in a bag is the risk simmer exists to bound — with a deadline, a battery floor, a thermal release and a watchdog — not one it removes.

## What would be a vulnerability

Anything that lets simmer leave `disablesleep` on with nothing scheduled to turn it off, that widens the sudoers rule beyond the two invocations above, that writes to `/etc/sudoers.d` without validating first, or that lets a caller get root through simmer.
Those are the promises; a hole in one of them is a report worth making.
