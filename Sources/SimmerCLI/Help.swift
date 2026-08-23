import Foundation

/// The friendly help — what someone typing --help needs, not what a
/// maintainer needs (that lives in the docs). Includes the complete exit-code
/// table, which CONTRACTS.md § v1 surface additions requires published here: a
/// caller that has to guess treats every non-zero as fatal, and `simmer
/// release` refusing is not the same as it failing.
enum Help {
    static let text = """
simmer keeps this Mac awake for a while — lid closed — then lets it sleep again.

TRY THIS
  simmer 2h                  stay awake for two hours
  simmer 2h -r "big build"   ...and say what for, so you can see it later
  simmer run -- npm test     stay awake exactly as long as this command runs
  simmer                     how much longer? what for? who else is asking?
  simmer +30m                need longer: 30 more minutes from now
  simmer down                finished early, let it sleep

HOW LONG
  simmer 45                  45 minutes — a bare number means minutes
  simmer 90m · 2h · 1h30m    the usual spellings all work
  simmer 1d                  a day — overnight wants --require-ac too
  simmer --until 23:00       until 11pm tonight (a time already past means
                             tomorrow, and the output says "tomorrow")
  simmer forever             no end time; it reminds you every 30 minutes

EVERYONE GETS THEIR OWN CLAIM
  Awake time is counted, not owned. You, an agent and a build can each hold a
  claim; the Mac stays awake until the last one ends, and nobody can take
  anybody else's away. So there is no --force any more, and nothing to
  negotiate.

  simmer status              every live claim, and when the machine actually sleeps
  simmer down                hand back YOUR claim   (canonical: simmer release)
  simmer down --all          hand back everything (only a person may)

  simmer cap 23:00           nothing past 23:00, whoever asks and however long
  simmer cap                 what the cap is
  simmer cap off             lift it
                             The cap is yours alone. Claims ask from below; it
                             rules from above, and an agent that runs into it is
                             told so plainly instead of finding an error to
                             route around.

IT STOPS BY ITSELF WHEN
  a claim's time runs out  ·  the battery drops below 20%  ·  the charger goes,
  if the claim asked for one  ·  the chip reports thermal pressure  ·  you run
  simmer down

  You get a notification five minutes before the end, one when the battery gets
  within 10 points of the floor, and another when it stops. Even if you close
  the terminal, log out, or the tool crashes, a background watchdog puts the
  machine back to normal. That is the point of it.

CHANGING THE DEFAULTS
  -r "text"                  what this is for; shown in the menu bar and log
  --min-battery 30           let go under 30% instead of 20%
                             (ignored while plugged in — charge does not matter then)
  --require-ac               end the claim the moment the charger is unplugged
  --until 23:00              an absolute time instead of a length
  --display-on               keep the screen lit too (default: the screen may
                             sleep — the Mac stays awake either way)
  --owner <name>             who is asking. It names your claim, and it is what
                             the menu bar shows. Several agents at once should
                             each pick their own (--owner agent:funnel)
  --max 2h                   with simmer run: hard cap on total awake time.
                             When it is reached the claim lapses but the
                             command keeps running — simmer never kills work

CHECKING ON IT
  simmer log                 what the watchdog has actually done
  simmer doctor              is everything wired up? fires a test notification
  simmer notify-test         queue one banner and say whether it can arrive —
                             banners come from Simmer.app or not at all
  simmer render swiftbar     draw a launcher surface (also: raycast, alfred)
  simmer --version

REMOVING IT
  make -C ~/.local/share/simmer uninstall     the app, the CLI, the guard
  sudo rm /etc/sudoers.d/simmer               the sudo rule (needs root)

FOR SCRIPTS AND AGENTS
  simmer budget --need 20m   "is there room to start a 20-minute job?"
  simmer budget --seconds    just the seconds remaining (-1 = no deadline)
  simmer status --json       the whole state as one JSON object, aggregate at
                             the top level, every claim in .claims
  simmer status --machine    the same as key=value lines, when jq is not around
  --json                     on EVERY command: what changed, plus the aggregate

EXIT CODES ARE API
  budget         0 fits (or no deadline) · 1 not enough · 3 NOTHING CLAIMED —
                 an absent guarantee, not a small budget. Do not conflate.
  run -- cmd     the command's own exit code, passed through untouched
  claim/extend/release/cap   0 ok · 1 refused (floor, cap, authority, parse)
  doctor         0 healthy · 1 something red

https://github.com/moralesl/simmer
"""
}
