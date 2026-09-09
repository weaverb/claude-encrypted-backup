# Registers a weekly Windows Task Scheduler task that runs the
# encrypted-backup script under WSL (recommended) or Git Bash.
#
# Run this yourself in an elevated PowerShell prompt. Do not run this
# through an AI agent — task registration is a privileged, one-time setup
# step, same principle as the rest of this skill's prerequisites.
#
# EDIT $ScriptPath below to point at your actual backup.sh location first.

$ScriptPath = "C:\Users\YOU\CHANGE\ME\backup.sh"   # EDIT ME

# Default: run under WSL (recommended — restic/rclone/jq are easiest to
# install there via your WSL distro's package manager).
$Action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "bash -lc `"$ScriptPath run --all`""

# Alternative: if you're using Git Bash instead of WSL, comment out the
# line above and use this one instead (adjust the Git install path if
# yours differs):
# $Action = New-ScheduledTaskAction -Execute "C:\Program Files\Git\bin\bash.exe" -Argument "-lc `"$ScriptPath run --all`""

$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName "EncryptedBackup" `
  -Action $Action -Trigger $Trigger -Settings $Settings `
  -Description "Weekly encrypted 3-2-1 backup (encrypted-backup Claude Code skill)"

Write-Host "Registered. Check it with: Get-ScheduledTask -TaskName EncryptedBackup"
Write-Host "Run it once now to test: Start-ScheduledTask -TaskName EncryptedBackup"
