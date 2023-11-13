#!/bin/bash

Plist=com.mdmexpertise.migration.plist

/bin/launchctl list | /usr/bin/grep $Plist
if [[ $? -eq 0 ]]; then
    /bin/launchctl unload /Library/LaunchDaemons/$Plist
fi

rm -rf /Library/migrate
rm -rf /Library/LaunchDaemons/$Plist

exit 0