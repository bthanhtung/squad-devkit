-- Opens a worker monitor split next to the manager's Ghostty terminal.
-- argv: manager terminal id, previous worker terminal id (or ""), working
-- directory, command, pane title. Returns the new terminal's id.
on run argv
	set managerId to item 1 of argv
	set previousId to item 2 of argv
	tell application "Ghostty"
		set managerTerminal to terminal id managerId
		set surfaceConfiguration to new surface configuration
		set initial working directory of surfaceConfiguration to item 3 of argv
		set command of surfaceConfiguration to item 4 of argv
		set newTerminal to missing value
		if previousId is not "" then
			try
				set newTerminal to split (terminal id previousId) direction down with configuration surfaceConfiguration
			end try
		end if
		if newTerminal is missing value then
			set newTerminal to split managerTerminal direction right with configuration surfaceConfiguration
		end if
		try
			perform action ("set_surface_title:" & item 5 of argv) on newTerminal
		end try
		focus managerTerminal
		return id of newTerminal
	end tell
end run
