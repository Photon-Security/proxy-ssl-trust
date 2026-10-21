#!/bin/zsh

#################### Written by Florian Bidabe #####################################
#                                                                                  #
#  DESCRIPTION: The purpose of this suite of scripts is to fix certificate trust   #
#               issues where clients (CLI mostly but also a few GUIs) fail to      #
#               connect as it does not trust Internal Certificate Authorities      #
#               found in KeychainAccess.                                           #
#               This script invokes other scripts to detect proxy settings and     #
#               create persistent connectivity for the current user.               #
#               It also support a variety of swithces for advanced troubleshooting #
#  INITIAL RELEASE DATE: 19-Sep-2024                                               #
#  AUTHOR: Florian Bidabe                                                          #
#  REVISION:    Major revamp, better stdout, better logging, and bug fixes         #
#                                                                                  #
#                                                                                  #
####################################################################################



#################################   Variables     ####################################
local scriptname=$(basename $(realpath $0))
local AppName="Proxy_SSL_Trust"
script_dir=$(dirname $(realpath $0))
version_file="$script_dir/VERSION"
if [[ -r "$version_file" ]]; then
    local version=$(< "$version_file")
fi
teefile="/tmp/$AppName.log"
invoked=true	# Set this variable to instruct other scripts that we've invoked them if the variable is set
if [[ -z ${BLUEW-} ]]; then
    source "$script_dir/lib/stderr_stdout_syntax.sh"
fi
####################################### Defining functions ###########################

# Display the Help Menu
help() {
	echo -e "Summary: This script is designed to manage and patch certificate stores on macOS systems.\nIt's primary function is to ensure that clients trust internal Certificate Authorities.\n"
	echo -e "Author: contact@photonsec.com.au\t\tgithub.com/Enelass\nRuntime: currently running as $(whoami)\nVersion: $version\n"
	echo -e "Usage: $script [OPTION]..."
  echo -e "  --help, -h\t\tShow this help menu"
  echo -e "  --version\t\tShow the version information"
	echo -e "  --list, -l\t\tList all the signing Root CAs from the MacOS Keychain Access, This is usefull if you want to check what Root CAs
	\t\tare supplied with the SOE, or what Root CAs are performing SSL Inspection"
	echo -e "  --var_uninstall\tRevert any changes made by --var, restoring to the original state"
	echo -e "  --var\t\t\tSet default shell environement variable to a known PEM Certificate Store containing internal and Public Root CA...
	\t\tThis is usefull if you need an easy fix for common CLI and within the user-context only..."
	echo -e "  --proxy_uninstall\tRevert any changes made by --proxy, restoring to the original state"
	echo -e "  --proxy\t\t${PURPLE}Default Mode${NC}, it tests various proxy addresses it finds in the pac file (if any), then install Alpaca to make use of it...
	\t\tOnce the proxy setup is complete, it proceeds to solving SSL Trust issues if SSL forward inspection or signing is in place."
	echo -e "  --scan_uninstall\tRevert any changes made by --scan, restoring to the original state"
	echo -e "  --scan, -s\t\tOnly scan for PEM Certificate Stores on the system. I will not patch it!
	\t\tThis is be useful if you're looking for a software certificate store but do not know where to find it"
	echo -e "  --patch_uninstall\tRevert any changes made by --patch, restoring to the original state"
	echo -e "  --patch\t\t(For Testing Only) Patch known PEM Certificate Stores (requires --scan) unless excluded...
	\t\tThis is usefull if you want to patch known certificate stores previously scanned (not recommended)..."
	exit 0
}



# Switch to list-only signing Root CAs certificates in Keychain Access
list() {
	switch="Internal Root CAs listing from Keychain Access"
	KAlist=1 # List MacOS Keychain Access certificates...
}

# Switch to download the latest PEM Certificate Store (cacert.pem) from the internet (curl.se) then patch it and reference it from the user's Shell config file (e.g. ~/.zshrc)
var() {
	switch="Set SSL Env Variables to Custom Certificate Store"
	var=1 # Set SSL Env Variables to Custom Certificate Store
}

# Switch to remove Environement variable from the user's Shell config and delete the custom PEM certificate store from the user's directory
var_uninstall() {
	switch="Revoking Shell and Env Variables + Deletion of custom PEM certificate file"
	var_uninstall=1 # Revoking files and unset variables from --var
}

# Switch to scan-only new pem files, but do not patch
scan() {
	switch="PEM Scanning"
	pemscan=1 # Do scan PEM Certificate Stores in User and System context
}

# Switch to revert all changed made by --scan. It'll delete the file generated by --scan
scan_uninstall() {
	switch="PEM Scanning uninstallation"
	scan_uninstall=1 # Remove all files created by --scan
}

# Switch to patch-only known (previously scanned) pem files / Quick mode
patch() {
	switch="Internal Root CAs listing & PEM Patching"
	pempatch=1 #pempatch=1 will invoke Keychain_InternalCAs.sh so no need to set KAlist=1 as it'd be redundant...
}

# Switch to restore all pem files that have been patched and revert from --path
patch_uninstall() {
	switch="PEM Patching uninstallation"
	patch_uninstall=1
}

# Switch to test proxy and pac file & install Alpaca as a daemon
proxy() {
	switch="Setting up proxy and PAC file"
	proxy=1 #pempatch=1 will invoke Keychain_InternalCAs.sh so no need to set KAlist=1 as it'd be redundant...
}

# Switch to revert all changed made by --proxy
proxy_uninstall() {
	switch="Proxy and PAC uninstallation"
	proxy_uninstall=1
}


# Function to check if we're running on MacOS
get_macos_version() { local product_name=$(sw_vers -productName); local product_version=$(sw_vers -productVersion); local build_version=$(sw_vers -buildVersion); echo "$product_name $product_version ($build_version)" }

# Function to check if a command exists
command_exists() { command -v "$1" >/dev/null 2>&1 }

# Function to check if a package is installed via Homebrew
brew_package_installed() { brew list | grep -qE "^$1$" }

# Function to attempt installing a package 3x times via Homebrew
attempt_install() {
    local package="$1"; local attempts=2
    while [ $attempts -gt 0 ]; do
        sudo -u "$user" brew install "$package" > /dev/null
        if [ $? -eq 0 ]; then
            logS "$package installed successfully."
            return 0
        fi
        logW "Failed to install $package. Attempts left: $attempts"
        attempts=$((attempts - 1))
    done
    logE "Failed to install $package after 2 attempts. Exiting..."
}



###########################   Script SWITCHES   ###########################
# Switches and Executions for the initial call (regardless of when)
if [[ $# -gt 1 ]]; then echo "${RED}Error:${NC} too many arguments. Please supply only one argument or none..." >&2; exit 1; fi

# No switches were supplied, run the default mode --proxy
if [[ $# -eq 0 ]]; then clear; proxy; fi

while [[ $# -gt 0 ]]; do
  case $1 in
  	--version) echo "$0 version: $version"; exit 0 ;;
    --help|-h) clear; help ;;
    --list|-l) list ;;
		--var) var ;;
		--var_uninstall) var_uninstall ;;
    --scan) scan ;;
		--scan_uninstall) scan_uninstall ;;
    --patch) patch ;;
    --patch_uninstall) patch_uninstall ;;
		--proxy) proxy ;;
		--proxy_uninstall) proxy_uninstall ;;
    *) echo "${RED}Error:${NC} unknown option '$1'" >&2; exit 1 ;;
  esac
  shift
done


##################################### Runtime ######################################

# Traps to stop background progress indicators when the main script terminates.
trap 'stop_spinner_sigint' SIGINT
trap 'stop_spinner' EXIT

clear
logI "  ---   ${PINK}SCRIPT: $script_dir/$scriptname${NC}   ---"
logI "        ${PINK}     This script serves as an entry point for various proxy and SSL trust utilities.${NC}	"
logI "Summary: This script performs various operations related to certificate trust and proxy configurations on a MacOS system"
logI "         It is designed to improve connectivity by managing certificates and proxy settings, ensuring that internal CAs are"
logI "         trusted and appropriate environment configurations are applied."
logI "         For more information, check usage with $scriptname --help"

# Welcoming stdin for unprivileged user
if [ "$EUID" -ne 0 ]; then
	logI "Execution specifics..."
	logI "   Switch description: $switch"
	logI "   This script is being executed by `whoami` / EUID: $EUID"
	# Scanning and Patching requires user elevation...
	if [[ "$pemscan" || "$pempatch" || "$patch_uninstall" ]]; then
  	logE "User elevation is required. Please run again as root or sudo"
	fi
fi

# Welcoming stdin for elevated user
if [ "$EUID" -eq 0 ]; then
	logI "Execution specifics..."
	logI "   Switch description: $switch"
	logI "   This script is running elevated as `whoami`"
	logged_user=$(stat -f "%Su" /dev/console)
	if [[ ! -z "${logged_user-}" ]]; then logI "   Logged-in user is $logged_user"; fi
fi

logI "Verifying System requirements..."
# Check if the operating system is Darwin (macOS)
if [ "$(uname)" != "Darwin" ]; then log "Error   - This Script is meant to run on macOS, not on: $(uname -v)"; exit 1; fi
logI "     Running on $(get_macos_version)"


# Check if Curl and Homebrew are installed
if ! command_exists brew; then logE " Homebrew is not installed. Please install it..."; else logI "     $(brew --version | awk {'print $1, $2'}) is already installed."; fi
if ! command_exists curl; then logI "cURL is not installed. Installing curl..."; attempt_install curl; else logI "     $(curl -V | head -n 1 | awk '{print $1, $2}') is already installed."; fi

#########################  Proxy and PAC File setup ##############################
if [[ ${proxy} -eq 1 ]]; then
	source "$script_dir/proxy/connect_noproxy.sh"
	if [[ $? -eq 0 ]]; then
		# If the script executed without major errors, we'll keep a permanent marker to indicate the setup was successfull
		touch "$script_dir/.proxy_ssl_trust.success"
	fi
	exit
fi
if [[ ${proxy_uninstall} -eq 1 ]]; then source "$script_dir/proxy/AlpacaSetup.sh" --uninstall; exit; fi


########################  Env Variables and Custom downloaded PEM #################
if [[ ${var} -eq 1 ]]; then source "$script_dir/SSL/PEM_Var.sh"; exit; fi
if [[ ${var_uninstall} -eq 1 ]]; then source "$script_dir/SSL/PEM_Var.sh" --uninstall; exit; fi


############################  SCANNING MacOS PEM Files #############################
if [[ ${pemscan} -eq 1 ]]; then source "$script_dir/SSL/PEM_Scanner.sh"; exit; fi
if [[ ${scan_uninstall} -eq 1 ]]; then source "$script_dir/SSL/PEM_Scanner.sh" --uninstall; exit; fi


##################  LISTING Internal Root CA from Keychain ########################
if [[ ${KAlist} -eq 1 ]]; then
	logI "    We will now look for Internal Root CA in the Keychain Access."; source "$script_dir/SSL/Keychain_InternalCAs.sh" --quiet
	if [[ -z "${IntCAList-}" ]]; then logE "   We couldn't find a list of Internal signing Root CAs to add to the various PEM certificate stores"; fi
fi

######################  PATCHING PEM Certificate Stores ##############################
if [[ ${pempatch} -eq 1 ]]; then source "$script_dir/SSL/PEM_Patcher.sh"; exit; fi
if [[ ${patch_uninstall} -eq 1 ]]; then source "$script_dir/SSL/PEM_Patcher.sh" --uninstall; exit; fi

# Truncate Log file to insure it isn't ever growing. Capped at 10,000 lines of codes
tail -n 10000 "$teefile" > "${teefile}.tmp" && mv "${teefile}.tmp" "$teefile"
