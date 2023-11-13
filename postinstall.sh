#!/bin/bash

launch_agent_plist_name='com.mdmexpertise.migration.plist'

launch_agent_base_path="/Library/LaunchDaemons/"

/bin/mkdir -p "$3/Library/migrate/Logs"
/bin/mkdir -p "$3/Library/migrate/Preference"
/bin/chmod -R 777 "$3/Library/migrate/Logs"
/bin/chmod -R 777 "$3/Library/migrate/Preference"

if [[ $3 == "/" ]] ; then
  if [ ! -e "$3${launch_agent_base_path}${launch_agent_plist_name}" ]; then
    echo "LaunchAgent missing, exiting"
    exit 1
  fi

  console_user=$(/usr/bin/stat -f "%Su" /dev/console)

  if [[ -z "$console_user" ]]; then
    echo "Did not detect user"
  elif [[ "$console_user" == "loginwindow" ]]; then
    echo "Detected Loginwindow Environment"
  elif [[ "$console_user" == "_mbsetupuser" ]]; then
    echo "Detect SetupAssistant Environment"
  else
    /bin/launchctl list | /usr/bin/grep 'migration'
    if [[ $? -eq 0 ]]; then
      /bin/launchctl unload "${launch_agent_base_path}${launch_agent_plist_name}"
    fi
    /bin/launchctl load "${launch_agent_base_path}${launch_agent_plist_name}"
  fi
fi

