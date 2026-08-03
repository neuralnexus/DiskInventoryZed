-- Disk Inventory Zed First Run Helper
-- Opens System Settings to Security & Privacy to help users allow the app

set theMessage to "If macOS Gatekeeper blocks this build of Disk Inventory Zed from opening, follow these steps:

To allow the app:

1. Click 'Open Security Settings' below
2. In System Settings, go to Privacy & Security
3. Scroll down to Security section
4. Click 'Open Anyway' next to Disk Inventory Zed
5. Click 'Open' in the confirmation dialog

You only need to do this once."

set theResult to display dialog theMessage buttons {"Open Security Settings", "Open Anyway", "Cancel"} default button "Open Security Settings" with icon note with title "Disk Inventory Zed - First Launch"

if button returned of theResult is "Open Security Settings" then
	-- Open System Settings to Privacy & Security
	do shell script "open /System/Library/PreferencePanes/Security.prefPane || open /System/Library/PreferencePanes/Security.prefPane || open x-apple.systempreferences:com.apple.preference.security"
	
	display dialog "System Settings has been opened.

1. Look for the message about Disk Inventory Zed in the Security section
2. Click 'Open Anyway'
3. Then try opening Disk Inventory Zed again" buttons {"OK"} default button "OK" with title "Next Steps"
	
else if button returned of theResult is "Open Anyway" then
	-- Try to launch the app directly - this will trigger the Gatekeeper prompt with Open Anyway option
	display dialog "If you've already seen the Gatekeeper warning, you can also:

1. Right-click (or Control-click) on DiskInventoryZed.app
2. Select 'Open' from the menu
3. Click 'Open' in the dialog

This is often the quickest method!" buttons {"OK"} default button "OK" with title "Alternative Method"
end if

return 0
