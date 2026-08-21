-- The notification channel for `simmer`, and the only reason it exists is the
-- icon.
--
-- osascript notifications are posted by Script Editor: a quill icon, a
-- misleading name, and silently dropped if Script Editor's notifications are
-- switched off. A notification's identity comes from the bundle that posts it,
-- so the only way to show simmer's own logo is to post from simmer's own bundle.
--
-- Content arrives through a file rather than arguments, because `open --args`
-- does not reach an applet's `on run argv` -- tested, it does not arrive. So
-- bin/simmer writes three lines (title, subtitle, body) and launches this.
on run
	set f to (POSIX path of (path to home folder)) & ".local/state/simmer/notify"
	try
		set txt to do shell script "cat " & quoted form of f
		set AppleScript's text item delimiters to (ASCII character 10)
		set parts to text items of txt
		set t to item 1 of parts
		set s to item 2 of parts
		set b to item 3 of parts
		if s is "" then
			display notification b with title t
		else
			display notification b with title t subtitle s
		end if
	end try
end run
