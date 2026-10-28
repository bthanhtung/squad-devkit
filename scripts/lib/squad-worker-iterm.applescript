-- Opens a worker monitor split next to the manager's iTerm2 session.
-- argv: manager session unique id, previous worker session unique id (or ""),
-- command, pane title. Returns the new session's unique id.
on run argv
	set managerId to item 1 of argv
	set previousId to item 2 of argv
	set paneCommand to item 3 of argv
	tell application "iTerm2"
		set managerSession to missing value
		set previousSession to missing value
		repeat with aWindow in windows
			repeat with aTab in tabs of aWindow
				repeat with aSession in sessions of aTab
					if unique id of aSession is managerId then set managerSession to aSession
					if previousId is not "" and unique id of aSession is previousId then set previousSession to aSession
				end repeat
			end repeat
		end repeat
		if managerSession is missing value then return ""
		if previousSession is not missing value then
			tell previousSession to set newSession to (split horizontally with default profile command paneCommand)
		else
			tell managerSession to set newSession to (split vertically with default profile command paneCommand)
		end if
		try
			tell newSession to set name to item 4 of argv
		end try
		tell managerSession to select
		return unique id of newSession
	end tell
end run
