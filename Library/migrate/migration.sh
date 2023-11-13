#!/bin/bash

#Variables
count=1
loggedInUser=$(/bin/ls -l /dev/console | /usr/bin/awk '{ print $3 }')
logged_in_uid=$(id -u "$loggedInUser")
usercheck=0
icon="/Library/migrate/Mobile_Device_Management_MDM.png"
info_URL="https://learn.microsoft.com/en-us/mem/intune/fundamentals/what-is-intune"

#JamfPro API Details
JamfURL="" #ex: https://caper.domain.com:8443
client_id=""
client_secret=""

# Path to SwiftDialog
dialogPath="/usr/local/bin/dialog"

# Path to PlistBuddy
pBuddy="/usr/libexec/PlistBuddy"

# How long until a deferral expires? Value in seconds.
deferralDuration="3600" #1hr

# How many deferrals until you no longer offer them?
deferralMaximum="1000" 

# Deadline Date. This is a unix epoch time value. 
# To get this value converted from a human readable date you can use a "unix epoch time" 
# calculator like this one: https://www.epochconverter.com/
deadlineDate="1704067199"  # 31st December 2023

#path to configuration profile.
deferralPlist="/Library/migrate/Preference/com.mdmexpertise.migration.plist"

#Logging
exec >> /Library/migrate/Logs/migration.log
function log_message()
{
    echo "$(date): $@" 
}

function cleanup_and_exit()
{
    log_message "${2}"
    exit "${1}"
}

#Wait for user to log in 
until [ $usercheck = 1 ]; do
    console_user=$(/usr/bin/stat -f "%Su" /dev/console)
    log_message "$console_user" 
    if [[ -z "$console_user" ]]; then
        log_message "Did not detect user"
        sleep 5
    elif [[ "$console_user" == "loginwindow" ]]; then
        log_message "Detected Loginwindow Environment"
        sleep 5
    elif [[ "$console_user" == "root" ]]; then
        log_message "Detected Loginwindow Environment"
        sleep 5    
    elif [[ "$console_user" == "_mbsetupuser" ]]; then
        cleanup_and_exit 0 "Exiting : Detect SetupAssistant Environment"
    else
        log_message "User Logged in , Proceeding...."
        usercheck=1
    fi
done    

# Check for Dialog and install if not found
function dialogCheck(){
  if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then
    log_message "Dialog not found. Installing..."
    /usr/sbin/installer -pkg "/tmp/dialog-2.1.0-4148.pkg" -target /
    log_message "Dialog Installed. Proceeding..."
  else 
    log_message "Dialog Installed. Proceeding..."
  fi
}

function check_the_things()
{
    profiles list | grep -wq "Microsoft.Profiles.MDM"
    if [ $? -eq 0 ]; then
        cleanup_and_exit 0 "Exiting : Already Enrolled to Intune."
    else
        log_message "Intune Profile Not Found, Proceeding...."
    fi    

    dialogCheck

    if [ -d "/Applications/Company Portal.app" ]; then
        log_message "Company Portal Installed. Proceeding..."
    else
        log_message "Company Portal Not Found. Installing......"
        bash /Library/migrate/InstallMCP.sh
    fi
    
}

function remove_Jamf()
{
   profiles list | grep "com.jamfsoftware.tcc.management"
    if [ $? -eq 0 ]; then
        log_message "Found Jamf Profiles.....Removing it....."
    else
        log_message "No Jamf Profiles found....Continue....."
    fi

    for identifier in $(/usr/bin/profiles -L | awk "/attribute/" | awk '{print $4}'); do
    /usr/bin/profiles -R -p "$identifier" >/dev/null 2>&1
    done

    /usr/local/jamf/bin/jamf removeMdmProfile
    /usr/local/jamf/bin/jamf removeFramework
    rm -rf /var/db/ConfigurationProfiles/       
    /usr/bin/profiles -D -f -v

    sleep 1
    count2=1
    profiles list | grep "com.jamfsoftware.tcc.management"
    if [ $? -eq 0 ]; then
        echo "Jamf profiles not removed yet.Might be the profiles are marked non-removable.Using Jamf API to unmanage the device"
        response=$(curl --location --request POST "$JamfURL/api/oauth/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "client_secret=$client_secret")
        IFS='"'
        read -ra newarr <<< "$response"
        bearerToken="${newarr[3]}"
        SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
        log_message "Serial number is $SERIAL"
        JAMF_ID=$(curl -X GET "$JamfURL/JSSResource/computers/serialnumber/$SERIAL" -H "accept: application/xml" -H "Authorization: Bearer $bearerToken" | xmllint --xpath '/computer/general/id/text()' -)
        log_message "JAMF ID for $SERIAL is $JAMF_ID"
        curl -X POST "$JamfURL/JSSResource/computercommands/command/UnmanageDevice/id/$JAMF_ID" -H "Content-Type: application/xml" -H "Authorization: Bearer $bearerToken" 
        profiles list | grep  "com.jamfsoftware.tcc.management"
        until [ $? -eq 0 ]; do
            if [ $count2 = 30 ] ; then
                cleanup_and_exit 0 "It's been 5 min's,haven't yet received the unmanage command...Exiting..."
            fi    
            log_message "Waiting for unmanage command...."       
            sleep 10
            ((count2=count2+1))
            profiles list | grep  "com.jamfsoftware.tcc.management"
        done
    else
        log_message "Jamf Profile is removed"
    fi  
}

function remove_JamfConnect()
{
    /usr/local/bin/authchanger -reset
    rm /usr/local/bin/authchanger
    rm /usr/local/lib/pam/pam_saml.so.2
    rm -r /Library/Security/SecurityAgentPlugins/JamfConnectLogin.bundle
    rm -rf /Applications/Jamf\ Connect.app
    rm /Library/LaunchAgents/com.jamf.connect.unlock.login.plist
}

function do_the_things()
{
    "$dialogPath" \
    --title "none" \
    --message  "### ***Please follow the steps below***\n 1. When Company Portal app open's ,Click sign-in and sign-in with your organization credentials.\n\n 2. Click Begin and then Download Profile.An MDM profile will be downloaded.\n\n 3. Click the profile notification from right top corner and install the profile from ***System Settings/System Preferences >  Profiles/Privacy & Security > Profiles***.\n\n 4. Double click the profile to install." \
    --messagefont "size=15" \
    --icon "$icon" \
    --centreicon \
    --iconsize 160 \
    --button1text "Quit" \
    --button1disabled  \
    --progress 3 \
    --moveable \
    --position "center" \
    --quitkey "m" \
    --progresstext "Removing the old MDM profiles"  &
    sleep 3 
    log_message "removing Jamf"
    remove_Jamf
    log_message "removing Jamf Connect"
    remove_JamfConnect
    networksetup -setairportnetwork en0 SpringerNature-Guest spr%wm3n$
    echo "progress: 1" >> /var/tmp/dialog.log
    sleep 5
    echo "progresstext: Jamf profiles are removed " >> /var/tmp/dialog.log 
    sleep 5
    echo "progress: 2" >> /var/tmp/dialog.log
    echo ""progresstext: Enrolling device to Intune.Please sign in with your organization email in Company Portal app"" >> /var/tmp/dialog.log
    sleep 5
    log_message "Launching Company Portal App"
    /bin/launchctl asuser "$logged_in_uid" sudo -iu "$loggedInUser" open /Applications/Company\ Portal.app
    sleep 5
    profiles list | grep -wq "Microsoft.Profiles.MDM"
    until [ $? -eq 0 ]; do
        if [ $count = 10 ] ; then
            execute_deferral
            exit 
        fi    
        log_message "Waiting for Intune Enrollment : $count"       
        sleep 60
        ((count=count+1))
        profiles list | grep -wq "Microsoft.Profiles.MDM"
    done  
    echo "button1: enable" >> /var/tmp/dialog.log
    sleep 2
    echo "progress: 3" >> /var/tmp/dialog.log
    sleep 3
    echo "progresstext: Migration Completed.Thank You..." >> /var/tmp/dialog.log 
    $pBuddy -c "Set DeferralCount 0" $deferralPlist
    $pBuddy -c "Set ActiveDeferral 0" $deferralPlist
}

function dialog_prompt_with_deferral()
{
    # This is where we define the dialog window options asking the user if they want to do the thing.
    "$dialogPath" \
    --title "none" \
    --message "### Mobile Device Management migration from Jamf Pro to Microsoft Intune\n\nThe Migration process takes 10-15 minutes.\n\nClick **Migrate Now** to start the migration or **Not Now** to do it later(After an hour).\n\n**Note:** Please click **OK** or **Allow** for any popup's during the migration.\n\nClick **Info** in the left bottom to know more about this process."\
    --messagealignment "centre" \
    --messagefont "size=18" \
    --icon "$icon" \
    --iconsize 180 \
    --button1text "Migrate Now" \
    --button2text "Not Now" \
    --centreicon \
    --moveable \
    --infobuttonaction "$info_URL" \
    --infobuttontext "Info"
}

function dialog_prompt_no_deferral()
{
    # This is where we define the dialog window options when we're no longer offering deferrals. "Aggressive mode" 
    # so to speak.
    "$dialogPath" \
    --title "none" \
    --message "### Mobile Device Management migration from Jamf Pro to Microsoft Intune\n\nThe Migration process takes 10-15 minutes.\n\nClick **Migrate Now** to start the migration or **Not Now** to do it later(After an hour).\n\n**Note:** Please click **OK** or **Allow** for any popup's during the migration.\n\nClick **Info** in the left bottom to know more about this process."\
    --messagealignment "centre" \
    --messagefont "size=18" \
    --icon "$icon" \
    --iconsize 180 \
    --button1text "Migrate Now" \
    --button2text "Not Now" \
    --centreicon \
    --moveable \
    --infobuttonaction "$info_URL" \
    --infobuttontext "Info"
}

function verify_config_file()
{
    # Check if we can write to the configuration file by writing something then deleting it.
    if $pBuddy -c "Add Verification string Success" "$deferralPlist"  > /dev/null 2>&1; then
        $pBuddy -c "Delete Verification string Success" "$deferralPlist" > /dev/null 2>&1
    else
        # This should only happen if there's a permissions problem or if the deferralPlist value wasn't defined
        cleanup_and_exit 1 "ERROR: Cannot write to the deferral file: $deferralPlist"
    fi

    # See below for what this is doing
    verify_deferral_value "ActiveDeferral"
    verify_deferral_value "DeferralCount"

}

function verify_deferral_value()
{
    # Takes an argument to determine if the value exists in the deferral plist file.
    # If the value doesn't exist, it writes a 0 to that value as an integer
    # We always want some value in there so that PlistBuddy doesn't throw errors 
    # when trying to read data later
    if ! $pBuddy -c "Print :$1" "$deferralPlist"  > /dev/null 2>&1; then
        $pBuddy -c "Add :$1 integer 0" "$deferralPlist"  > /dev/null 2>&1
    fi

}

function check_for_active_deferral()
{
    # This function checks if there is an active deferral present. If there is, then it exits quietly.

    # Get the current deferral value. This will be 0 if there is no active deferral
    currentDeferral=$($pBuddy -c "Print :ActiveDeferral" "$deferralPlist")

    # If unixEpochTime is less than the current deferral time, it means there is an active deferral and we exit
    if [ "$unixEpochTime" -lt "$currentDeferral" ]; then
        cleanup_and_exit 0 "Active deferral found. Exiting"
    else
        log_message "No active deferral."
        # We'll delete the "human readable" deferral date value, if it exists.
        $pBuddy -c "Delete :HumanReadableDeferralDate" "$deferralPlist"  > /dev/null 2>&1
    fi
}


function execute_deferral()
{
    deferralDateSeconds=$((unixEpochTime + deferralDuration ))
    deferralDateReadable=$(date -j -f %s $deferralDateSeconds)
    deferralCount=$(( deferralCount + 1 ))

    # Writing deferral values to the plist
    $pBuddy -c "Set ActiveDeferral $deferralDateSeconds" $deferralPlist
    $pBuddy -c "Set DeferralCount $deferralCount" $deferralPlist
    $pBuddy -c "Add :HumanReadableDeferralDate string $deferralDateReadable" "$deferralPlist"  > /dev/null 2>&1

    # Deferral has been processed. Exit cleanly.
    cleanup_and_exit 0 "User chose deferral $deferralCount of $deferralMaximum. Deferral date is $deferralDateReadable"
}

verify_config_file

unixEpochTime=$(date +%s)

check_for_active_deferral

check_the_things

deferralCount=$($pBuddy -c "Print :DeferralCount" $deferralPlist)

# Check if Deadline has been set, and if we are now past it
if [ ! -z "$deadlineDate" ] && [ "$deadlineDate" -lt "$unixEpochTime" ]; then
    allowDeferral="false"
# Check if the number of deferrals used is greater than the maximum allowed
elif [ "$deferralCount" -ge "$deferralMaximum" ]; then
    allowDeferral="false"
else
    # Deadline isn't past and the deferral count hasn't been exceeded, so we'll allow deferrals.
    allowDeferral="true"
fi

# If we're allowing deferrals, then
if [ "$allowDeferral" = "true" ]; then
    # Prompt the user to ask for consent. If it exits 0, they clicked OK and we'll do the things
    if dialog_prompt_with_deferral; then
        # Here is where the actual things we want to do get executed
        do_the_things
        thingsExitCode=$?
        # Capture the exit code of our things, so we can exit the script with the same exit code
        cleanup_and_exit $thingsExitCode "Things were done. Exit code: $thingsExitCode"
    else
        execute_deferral
    fi
else
    # We are NOT allowing deferrals, so we'll continue with or without user consent
    dialog_prompt_no_deferral
    do_the_things
    # Capture the exit code of our things, so we can exit the script with the same exit code
    thingsExitCode=$?
    cleanup_and_exit $thingsExitCode "Things were done. Exit code: $thingsExitCode"
fi
