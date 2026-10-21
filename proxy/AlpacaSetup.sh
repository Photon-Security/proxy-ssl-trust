#!/bin/zsh
#################### Written by Florian Bidabe #####################################
#                                                                                  #
#  DESCRIPTION: The purpose of this script is to provide various CLI on MacOS with #
#                a custom PEM certificate store including public and internal Root #
#                certificate authorities. This will resolve number of connectivity #
#                issues where CLI not relying on the MacOS Keychain Access can     #
#                still trust internally signed servers using an Internal Root CA   #
#                and trust https connections where SSL forward inspection is       #
#                performed and signed on a fly by a proxy/ngfw internal CA.        #
#  INITIAL RELEASE DATE: 19-Mar-2025                                               #
#  AUTHOR: Florian Bidabe                                                          #
#  LAST RELEASE DATE: 04-Apr-2025                                                 #
#  VERSION: 0.2                                                                    #
#  REVISION: 0.3                                                                      #
#                                                                                  #
#                                                                                  #
####################################################################################

#################################### Variables ####################################
version="v0.2"
local scriptname=$(basename $(realpath $0))
local current_dir=$(dirname $(realpath $0))
if [[ -z ${BLUEW-} ]]; then source "$current_dir/../lib/stderr_stdout_syntax.sh"; fi
variables=("all_proxy" "ALL_PROXY" "http_proxy" "HTTP_PROXY" "https_proxy" "HTTPS_PROXY" "no_proxy" "NO_PROXY")	# Proxy Environment Variables

########################## Standalone Exec - Specifics #############################
# If not invoked by another script, we'll set some variable for standalone use otherwise this would be ineritated by the source script along with $teefile...
if [[ -z "${teefile-}" ]]; then 
	AppName="ProxyAutoSetup"
	teefile="/tmp/$AppName.log"
	version=0.3
	
    logonly "------------------------------ new execution ------------------------------"
    log "Summary - The purpose of this script is to check network interfaces for PAC file settings, ensure Alpaca proxy\n\t\t\t      is installed and running if a PAC file is being used, and manage necessary proxy configurations."
    log "Author  - contact@photonsec.com.au\t\tgithub.com/Enelass"
    log "Runtime - Currently running as $(whoami)"
    logonly "Info - This script was invoked directly... Setting variable for standalone use..."
fi

############################## Defining functions ##################################
# Function to exit gracefully if running standalone
exit_if_standalone () {
  # If this script is running standalone, let's stop here...
  if [[ -z ${invoked-} ]]; then exit 0; fi
}

uninstall() {
	if [[ -n $uninst ]]; then log "Info    - Uninstall switch was called"; fi
	log "Info    -    Let's delete the Alpaca binaries, settings and env var ..."
	# Revert Shell Config file
	CONFIG_FILE_BAK=$(find $HOME -maxdepth 1 -name "*.pre-alpacasetup" 2>/dev/null)
	if [[ -n "$CONFIG_FILE_BAK" && -f "$CONFIG_FILE_BAK" && -f "$CONFIG_FILE" ]]; then
		mv $CONFIG_FILE_BAK $CONFIG_FILE
		if [ $? -eq 0 ]; then log "Info    -    $CONFIG_FILE has been restored"; fi
		source $CONFIG_FILE
	fi

	# Uninstall Alpaca only if user requested a manual uninstall, otherwise we'll just clear the Shell config file (e.g. ~/.zshrc) from the introduced changes
	if [[ -n $uninst ]]; then
		log "Info    - Uninstall switch was called"
		brew services stop alpaca > /dev/null 2>&1
		brew untap samuong/alpaca > /dev/null 2>&1
		brew uninstall alpaca     > /dev/null 2>&1
		log "Info    -    Homebrew settings and tap for Alpaca were revoked..."
		if where alpaca > /dev/null 2>&1; then
			log "Info    -    Unfortunately, it did not remove its binary, we'll remove it if you're local admin or if you're part of the sudoers"
			log "             Please enter your admin password. If you cannot, simply cancel the elevation prompts and the script will continue..."
			rm -f $(where alpaca) 2>/dev/null
		fi
	fi
}

shell_var(){
	# Calling default user and Shell config scripts since these variables are a requirement 
	source "$current_dir/../lib/user_config.sh" --quiet
	logI "${GREEN}   Env Var - ${NC}Are proxy related Environment Variables currently set ?"
	# Loop through each variable and check if it is set
	for var in "${variables[@]}"; do
		if [[ -n ${(P)var} ]];
			then setvar+=$(echo "$var is set to ${(P)var} - ")
			logI "       Yes, $var is set to ${(P)var}"
		fi
	done
	if [[ -z ${setvar-} ]]; then
		logI "       No, proxy related variables are not set in this session..."
	fi

	check_set_proxy_var "$CONFIG_FILE"
}

# Function to check if the variable is set in the configuration file
check_set_proxy_var() {
    logI "${GREEN}   Declared Var - ${NC}Are proxy related Environment Variables declared in $CONFIG_FILE ?"
    local file=$1
    unset patchrc
    # check for pattern like http_proxy or https_proxy
    for var in "${variables[@]}"; do
        if grep -qiE "^(export )?$var=.*" "$file"; then
            logI "       Found individual entry: $(cat "$file" | grep -E "^(export )?$var=.*" | xargs)"
            logI "       We will delete these individual entries"
            logI "       This serves to consolidate and avoid issues with conflicties proxy settings"
           patchrc=true  # Delete the individual entries since we want to set one entry for all
        fi
    done
    
    # Also check for pattern like {all,http,https}_proxy
    if ! grep -qiE "^(export ){all,http,https}_proxy=http://localhost:3128" "$file"; then
        logI "       Could not find the right proxy variable for Alpaca in "$file""
        patchrc=true 	# We couldn't find the right setting, so we'll add it
    fi

    if [[ -n $patchrc ]]; then
    	logI "       We need to patch $CONFIG_FILE to add a unique environment variable for Alpaca:"
    	logI "       We'll append this to the file, export {all,http,https}_proxy=http://localhost:3128"
    	logI "       Ensuring we have a back-up for $CONFIG_FILE prior to making changes..."
        CONFIG_FILE_BAK="$CONFIG_FILE.pre-alpacasetup"
        cp -n "$CONFIG_FILE" "$CONFIG_FILE_BAK" > /dev/null 2>&1
        if [[ -f "$CONFIG_FILE.pre-alpacasetup" ]]; then log "Info    -      Backup file can be found at "$CONFIG_FILE_BAK""; fi
        sed -i '' '/^export.*_proxy=/d' "$file"
        echo 'export {all,http,https}_proxy=http://localhost:3128' >> "$CONFIG_FILE"
        source $CONFIG_FILE # This will only affect this subshell...
        logW "       ${GREENW}source $CONFIG_FILE${NC} will need to be run by the user for the changes to be effective!"
    else
    	logI "       The right environment variable for Alpaca was already found in $CONFIG_FILE"
    	logI "       export {all,http,https}_proxy=http://localhost:3128"
    fi
}

install_alpaca() {
    # Check if Homebrew is installed as we need it to install Alpaca...
    if ! command -v brew > /dev/null 2>&1; then
      logE "This script requires Homebrew, please install it...\nIf you're corporate, you might have it packaged by your provisioning/SOE team (e.g. JAMF)\nOtherwise, you can install it as per: https://brew.sh/"
    else
      logI "       Attempting to installing Alpaca with $(brew --version)"
    fi
    # Attempt installing Alpaca up to 3 times
    local attempt=1;     local max_attempts=3;    local success=0
    brew tap samuong/alpaca > /dev/null 2>&1
    while [ $attempt -le $max_attempts ]; do
      logI "       Attempt $attempt to install Alpaca..."
      if brew install alpaca > /dev/null 2>&1; then
        success=1
        break
      else
        logW "      Attempt ( $attempt / $max_attempts) failed. Retrying..."
        attempt=$((attempt + 1))
      fi
    done
    
    # Check if Alpaca was successfully installed
    if [ $success -eq 1 ] && command -v alpaca > /dev/null 2>&1; then
      logI "       $(alpaca --version) is now installed"
      brew services start alpaca > /dev/null 2>&1
    else
      # If we couldn't download or install Alpaca, maybe it'll work without any proxy settings (direct connection)
      if [[ -z ${failed_install-} ]]; then	
      	logW "       We failed installing Alpaca...."
      	logI "          We'll try installing one more time, but without proxy settings..."
      	failed_install=true
		unset ALL_PROXY all_proxy ALL_proxy HTTP_PROXY http_proxy HTTP_proxy HTTPS_PROXY https_proxy HTTPS_proxy
      	install_alpaca
      else
      	logE "We failed installing Alpaca, please install it manually as per: https://github.com/samuong/alpaca"
      fi
    fi
}

# Detect Alpaca independently from its installation method. Homebrew ownership
# is useful for service management, but is not required when another package
# manager or an administrator already supplied a working daemon.
is_brew_alpaca(){
	local alpaca_path
	logI "   ${GREEN}Install - ${NC}Is Alpaca installed?"

	if ! alpaca_path=$(command -v alpaca 2>/dev/null); then
		logI "       Alpaca is not installed."
		install_alpaca
		alpaca_path=$(command -v alpaca 2>/dev/null) || return 1
	fi

	alpaca_installed=true
	if command -v brew >/dev/null 2>&1 && brew list --formula alpaca >/dev/null 2>&1; then
		brew_managed_alpaca=true
		logS "       $(alpaca --version) is installed by Homebrew at '$alpaca_path'."
	else
		unset brew_managed_alpaca
		logW "       $(alpaca --version) is installed at '$alpaca_path', but is not managed by Homebrew."
		logI "       Continuing with the existing installation; Homebrew service management will be skipped."
	fi
}

# Function to verify if the localhost:3128 socket is free
is_socket_free() {
	LISTENING_ON_3128=$(lsof -iTCP:3128 -sTCP:LISTEN -P -n 2>/dev/null)			# What's listening on TCP3128?
	unset alpaca3128
	logI "${GREEN}   Socket - ${NC}Is anything listening on TCP 3128 ? (We need that socket)"
	if [[ -n "$LISTENING_ON_3128" ]]; then
		# Something is listening on 3128
		if echo "$LISTENING_ON_3128" | grep -q alpaca; then
			logS "       Yes, Alpaca is listening on TCP3128"
			logI "       $(echo "$LISTENING_ON_3128" | grep "(LISTEN)" | grep -v "::1")"
			alpaca3128=true
		else
			logW "       Something is listening on TCP3128, but that isn't Alpaca... Maybe CNTLM ?"
			logI "       Please uninstall whatever is listening, since we cannot bind if the address is already in use!"
			logE "       Aborting... $(echo "$LISTENING_ON_3128" | grep "(LISTEN)" | grep -v "::1")"
		fi
	else
		logS "       Nothing is listening on TCP3128, the port is free for Alpaca to use it..."
	fi
}


# Function to check whether Alpaca is listening and listening on the right socket
alpaca_listening() {
	logI "   ${GREEN}Process - ${NC} Is Alpaca listening on any port but TCP3128?"
	start_spinner "Please wait, ${GREENW}lsof${NC} can occasionaly take a while..."
	Is_Alpaca_Listening=$(lsof -sTCP:LISTEN -P -i -a -c alpaca 2>/dev/null)		# Is Alpaca listening on any ports?
	stop_spinner
	if [[ -n "$Is_Alpaca_Listening" ]]; then 
		if echo "$Is_Alpaca_Listening" | grep " (LISTEN)" | grep -qv ":3128" ; then
			logW "       Alpaca appears to be listening on another port..."
			logI "       Please ensure Alpaca is configured to listen only on TCP 3128... Aborting!"
			logS "       $(echo "$Is_Alpaca_Listening" | grep " (LISTEN)" | grep -v ' IPv6 ' | tail -n +2)" 
		else
			logI "       Nope, no conflict detected, moving one..."
		fi
	else
		logS "       No, Alpaca isn't listening on any ports..."
	fi
}

# Function to start Alpaca as a serice/daemon (auto-start with the OS)
alpaca_service() {
	logI "   ${GREEN}Service - ${NC} Is Alpaca service started?"
	if [[ -z ${brew_managed_alpaca-} ]]; then
		local launchd_entry
		launchd_entry=$(launchctl list 2>/dev/null | grep -i 'alpaca' | head -n 1)
		if [[ -n ${alpaca3128-} ]]; then
			alprunning=true
			logS "       The existing Alpaca process is already listening on TCP 3128."
		else
			logW "       Alpaca is installed but is not currently listening on TCP 3128."
		fi
		if [[ -n "$launchd_entry" ]]; then
			logI "       A launchd job is registered: $(print -r -- "$launchd_entry" | awk '{print $3}')"
		else
			logW "       Auto-start could not be confirmed because this installation is not managed by Homebrew."
		fi
		return 0
	fi

	start_spinner "Please wait, ${GREENW}brew services${NC} can occasionaly take a while..."
	if ! brew services info alpaca | grep "PID:" > /dev/null 2>&1; then
		stop_spinner
		if [[ -n $alpaca3128 ]]; then
			logW "       Alpaca is listening on 3128 but the service is not started..."
			logE "       Kill Alpaca so free up the network socket and try again. Aborting..."
		fi
		logI "       Alpaca service/daemon is not running. Attempting to start it..."
		for n in 1 2 3; do
		    brew services start alpaca > /dev/null
		    if [ $? -ne 0 ]; then 
		    	logW "       Failed to start Alpaca service on attempt $n."
		    else
		    	logI "       Alpaca service was started on $n attempt."
		    	alprunning=true
		    	break
		    fi
		done
		if [[ ! $alprunning == "true" ]]; then
			logW "  Service failed to start after 3 attempts."
			logI "  We'll attempt reinstalling Alpaca..."
			if [[ -z "${HOME_DIR-}" ]]; then source "$current_dir/../lib/user_config.sh" --quiet; fi
			uninst=1; uninstall; sleep 5
			install_alpaca; sleep 5
			logI "  Last rounds of attempts to start Alpaca"
			for i in 1 2 3; do
			    logI "  Attempt $i to start Alpaca service..."
			    brew services start alpaca > /dev/null
			    if [ $? -ne 0 ]; then 
			    	logW "    Failed to start Alpaca service on attempt $n."
			    else
			    	logI "    Alpaca service was started on $n attempt."
			    	alprunning=true
			    	break
			    fi
			done
		fi
	else
		stop_spinner
		logI "       Alpaca service/daemon is already running!"
		alprunning=true
	fi	
	if [[ ! $alprunning == "true" ]]; then
		logE "  We could not start Alpaca. Maybe try again after a reboot, or install it manually..."
	fi
	sleep 5 # Give a few seconds for the service to start listening...
}

# Function to attempt installing (with retries) a package via Homebrew
attempt_install() {
    local package="$1"; local attempts=3
    while [ $attempts -gt 0 ]; do
        brew install "$package" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            logI "   $package installed successfully."
            return 0
        fi
        logE "   Failed to install $package. Attempts left: $attempts"
        logI "   Let's try without proxy settings..."
        attempts=$((attempts - 1))
       unset ALL_PROXY all_proxy ALL_proxy HTTP_PROXY http_proxy HTTP_proxy HTTPS_PROXY https_proxy HTTPS_proxy
    done
    logE "Failed to install $package after 3 attempts. Exiting..."
}

# Function to display the Help Menu
help() {
    log "Summary - The purpose of this script is to check network interfaces for PAC file settings, ensure Alpaca proxy\n\t\t\t      is installed and running if a PAC file is being used, and manage necessary proxy configurations."
    log "Author:  contact@photonsec.com.au\t\tgithub.com/Enelass"
    log "Runtime: currently running as $(whoami)"
    log "Usage: $@ [OPTION]..."
    log "  --help, -h\tDisplay this help menu..."
    log "  --version, -v\tDisplay $scriptname's version..."
    log "  --uninstall\tRemove the environment variables from Shell config file and remove Alpaca files and settings"
    log "  By default, if no switches are specified, it will install Alpaca unless it is running already..."
    exit 0
}


##################################### Runtime ######################################

###########################   Script SWITCHES   ###########################
# Switches and Executions for the initial call (regardless of when)
while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h) help ;;
	--version|-v) log "Version - AlpacaSetup.sh $version"; exit 0 ;;
    --uninstall|-u) uninst=1; exit ;;
   *) ;;
  esac
  shift
done

# If we want to uninstall, that'd be now...
if [[ uninst -eq 1 ]]; then
	# Uninstall requires default user and Shell config variables...
	if [[ -z "${HOME_DIR-}" ]]; then source "$current_dir/../lib/user_config.sh" --quiet; fi
	uninstall
fi


echo; logI "  ---   ${PINK}SCRIPT: $current_dir/$scriptname${NC}   ---"
logI "        ${PINK}     This script is intended to check if Alpaca Daemon is setup and running on TCP 3128...${NC}"
logI "${GREEN}REQUIREMENTS - ${NC}Running a few checks prior to installing Alpaca..."


# Check if anything is listening on TCP3128
#    If something else than Alpaca is listening on 3128, it will error out...
is_socket_free

# Check if Alpaca is listening on TCP3128 or other ports
#    If Alpaca is listning on another port than 3128, It will also error out...
alpaca_listening

# Check whether Alpaca is installed. A non-Homebrew installation is accepted;
# Homebrew is used only when Alpaca is absent or when managing its own service.
is_brew_alpaca || logE "Alpaca is not installed and could not be installed."

# Now that Alpaca is installed, we should be able to start the service. Let's try...
#   If it fails starting it, it will error out, but before it'll try multiple times, and attempt a re-install if necessary
alpaca_service

# Now that Alpaca is installed and running, let's check if it is listening...
is_socket_free
if [[ -z ${alpaca3128-} ]]; then
	logE "Alpaca is expected to be listening on TCP 3128... Aborting!"
fi

# Assuming we have a PAC File, Alpaca is installed and running as expected
# It's time to check if the proxy settings are well set and the connection can be established...
# Let's inspect the file for existing environment variables & Let's reference this cacert.pem in the Shell Interpreter config file.
shell_var

# Now that all requirements are met, we'll test the connectivity or revert the changes made by this script...
logI "${GREEN}   Connect - ${NC}We will now run some connectivity tests..."
invoked_by_alpaca=true
source "$current_dir/connect_proxy_nossl.sh"

# Function to exit gracefully if running standalone
exit_if_standalone

# The local proxy is installed and running, we'll now test connectivity and see whether or not the connection is SSL intercepted
logI "       We will now test web requests and whether these are SSL intercepted or not..."
source "$current_dir/connect_ssl.sh"
