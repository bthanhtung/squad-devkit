on run argv
	tell application "Ghostty"
		activate
		set surfaceConfiguration to new surface configuration
		set initial working directory of surfaceConfiguration to item 1 of argv
		set wait after command of surfaceConfiguration to true
		set command of surfaceConfiguration to item 2 of argv
		set newWindow to new window with configuration surfaceConfiguration
		set managerTerminal to focused terminal of selected tab of newWindow
		try
			perform action "set_surface_title:Claude · manager" on managerTerminal
		end try
		focus managerTerminal
	end tell
end run
