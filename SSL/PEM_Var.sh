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
#  LAST RELEASE DATE: 19-Mar-2025                                                  #
#  VERSION: 0.1                                                                    #
#  REVISION:                                                                       #
#                                                                                  #
#                                                                                  #
####################################################################################
version=0.2
cacertURL="https://curl.se/ca/cacert.pem"
local scriptname=$(basename $(realpath $0))
local current_dir=$(dirname $(realpath $0))
variables=("REQUESTS_CA_BUNDLE" "SSL_CERT_FILE")
extravarfile="$current_dir/ssl_vars.config"
exclusion_file="$current_dir/ca_exclusions.conf"

# If not invoked/sourced by another script, we'll set some variable for standalone use otherwise this would be ineritated by the source script along with $teefile...
if [[ -z ${BLUEW-} ]]; then source "$current_dir/../lib/stderr_stdout_syntax.sh"; fi
if [[ -z "${invoked-}" ]]; then 
    echo -e "\n\nSummary: The purpose of this script is to provide various CLI on MacOS with environment variables referencing a custom PEM certificate store including public and internal Root
         certificate authorities. This will resolve number of connectivity issues where CLI not relying on the MacOS Keychain Access can still trust internally
         signed servers using an Internal Root CA and trust https connections where SSL forward inspection is performed and signed on a fly by a proxy/ngfw internal CA."
    echo -e "Author:  contact@photonsec.com.au\t\tgithub.com/Enelass\nRuntime: currently running as $(whoami)"
    echo "This script was invoked directly... Setting variable for standalone use..."
    
    #################################   Variables     ####################################
    AppName="PEM_EnvVar"
    teefile="/tmp/$AppName.log"
    version=0.2
    ######################################################################################
fi


# Function to display the Help Menu
help() {
    clear
    echo -e "Summary: The purpose of this script is to provide various CLI on MacOS with environment variables referencing a custom PEM certificate store including public and internal Root
         certificate authorities. This will resolve number of connectivity issues where CLI not relying on the MacOS Keychain Access can still trust internally
         signed servers using an Internal Root CA and trust https connections where SSL forward inspection is performed and signed on a fly by a proxy/ngfw internal CA."
    echo -e "Author:  contact@photonsec.com.au\t\tgithub.com/Enelass\nRuntime: currently running as $(whoami)\nVervion: $version\n"
    echo -e "Usage: $@ [OPTION]..."
    echo -e "  --help, -h\tDisplay this help menu..."
    echo -e "  --download, -d\tBuild the validated PEM bundle without changing shell variables"
    echo -e "  --uninstall\tRemove the environement variables from Shell config file and remove downloaded files and backups"
    echo -e "  By default, if no switches are specified, it will run standone with verbose information"
    exit 0
}

# Function to check if we're running on MacOS
get_macos_version() { local product_name=$(sw_vers -productName); local product_version=$(sw_vers -productVersion); local build_version=$(sw_vers -buildVersion); echo "$product_name $product_version ($build_version)" }


extravar(){
	if [[ -f "$extravarfile" ]]; then 
		# Read variables from ssl_vars.config, ignoring comments and stripping quotes
		while IFS= read -r line; do
		  [[ $line =~ ^# ]] && continue
		  [[ $line =~ ^\"(.+)\"$ ]] && line="${match[1]}"
		  
		  # Regex to allow only uppercase letters, numbers, underscores, and dashes
		  if [[ -n $line && $line =~ ^[A-Z0-9_-]+$ ]]; then
		    variables+=("$line")
		  fi
		done < "$extravarfile"

		# Remove duplicates and sort
		variables=($(printf "%s\n" "${variables[@]}" | sort -u))
	fi
}

uninstall(){
	if [[ -z ${overwrite-} ]]; then logI "    Requesting uninstallation" ; fi
	source "$current_dir/../lib/user_config.sh"
	pattern='.config\/cacert\/cacert.pem'
	for var in "${variables[@]}"; do unset "$var"; done # Loop through the array and unset custom Certificate Store variable for various clients
	if [[ -f "$CONFIG_FILE" ]]; then 
		 sed -i '' "/"$pattern"/d" "$CONFIG_FILE"
		 if [[ $? -ne 0 ]]; then
		 	logE " Parsing the Shell Config file failed... aborting!"
		 else 
		 	logI "    Entries in the Shell config file at $CONFIG_FILE were cleaned-up..."
		 	source $CONFIG_FILE		# Reload Shell config file to make the changes (restore) effective
		 fi
	else
		logE "    Shell config file wasn't found..."
	fi
	
	if [[ -d $HOME_DIR/.config/cacert/ ]]; then
		rm -Rf "$HOME_DIR/.config/cacert/" 2>/dev/null
		if [[ $? -eq 0 ]]; then log "Info    -    Files downloaded by this script were cleaned-up..."; fi
	else logE " $HOME_DIR/.config/cacert/ could not be found! You probably already have requested an uninstallation..."
	fi
	if [[ -z ${overwrite-} ]]; then exit 0 ; fi
}

# Add only the internal roots already approved by Keychain_InternalCAs.sh.
trustca() {
	local cacert="$1" certname cert_file fingerprint exported_cert
	local -A bundle_fingerprints
	local added=0

	if [[ ! -f "$cacert" ]]; then
		logW "    Custom certificate store could not be located at '$cacert'."
		return 1
	fi

	# Exact fingerprints replace the former partial-base64 duplicate check.
	local split_dir=$(mktemp -d "${TMPDIR:-/tmp}/pem-var-roots.XXXXXX") || return 1
	awk -v dir="$split_dir" '
		/-----BEGIN CERTIFICATE-----/ { in_cert=1; count++; file=sprintf("%s/cert_%06d.pem", dir, count) }
		in_cert { print > file }
		/-----END CERTIFICATE-----/ && in_cert { close(file); in_cert=0 }
	' "$cacert"
	for cert_file in "$split_dir"/cert_*.pem(N); do
		fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr -d ':[:space:]')
		[[ -n "$fingerprint" ]] && bundle_fingerprints[$fingerprint]=1
	done
	rm -rf "$split_dir"

	logI "    Adding currently trusted internal root CAs from macOS Keychain Access:"
	while IFS= read -r certname; do
		[[ -z "$certname" ]] && continue
		exported_cert=$(mktemp "${TMPDIR:-/tmp}/internal-root.pem.XXXXXX") || return 1
		if ! security find-certificate -c "$certname" -p > "$exported_cert" 2>/dev/null \
			|| ! openssl x509 -in "$exported_cert" -noout >/dev/null 2>&1; then
			logW "       Unable to export '$certname'; skipping it."
			rm -f "$exported_cert"
			continue
		fi
		fingerprint=$(openssl x509 -in "$exported_cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr -d ':[:space:]')
		if [[ -n "${bundle_fingerprints[$fingerprint]-}" ]]; then
			logI "       ${BLUEW}$certname${NC} is already present."
		else
			print >> "$cacert"
			cat "$exported_cert" >> "$cacert" || { rm -f "$exported_cert"; return 1; }
			bundle_fingerprints[$fingerprint]=1
			added=$((added + 1))
			logS "       Added ${BLUEW}$certname${NC}."
		fi
		rm -f "$exported_cert"
	done <<< "$CAList"
	logI "    Added $added internal root CA(s); the completed bundle will now be validated."
}

shell_var(){
	log "Info    -    Looking for CA related Environment Variables in Shell Config $CONFIG_FILE"
	local -A checked_pem_files
	local shell_validation_status=0
	checked_pem_files=()

	configured_pem_path() {
		local assignment="$1"
		local pem_path="${assignment#*=}"
		pem_path=$(print -r -- "$pem_path" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

		# Strip one matching pair of quotes without evaluating shell code from the
		# user's configuration file.
		if [[ "$pem_path" == \"*\" || "$pem_path" == \'*\' ]]; then
			pem_path="${pem_path#?}"
			pem_path="${pem_path%?}"
		fi

		case "$pem_path" in
			'~/'*) pem_path="$HOME_DIR/${pem_path:2}" ;;
			'$HOME/'*) pem_path="$HOME_DIR/${pem_path:6}" ;;
			'${HOME}/'*) pem_path="$HOME_DIR/${pem_path:8}" ;;
		esac
		print -r -- "$pem_path"
	}

	validate_configured_pem() {
		local configured_pem="$1"
		local validation_status

		if [[ "$configured_pem" == "$customcacert" ]]; then
			if (( ! ${+checked_pem_files[$configured_pem]} )); then
				logS "         Referenced PEM '$configured_pem' was rebuilt and validated during this run."
				checked_pem_files[$configured_pem]=0
			fi
			return 0
		fi
		if [[ -z "$configured_pem" ]]; then
			logW "         The assignment has an empty PEM path; it could not be validated."
			return 1
		fi
		if [[ ! -r "$configured_pem" ]]; then
			logW "         Referenced PEM '$configured_pem' is not readable; it could not be validated."
			return 1
		fi
		if (( ${+checked_pem_files[$configured_pem]} )); then
			return "${checked_pem_files[$configured_pem]}"
		fi

		logI "         Validating referenced PEM '$configured_pem'."
		source "$current_dir/PEM_Check.sh" --quiet --cafile "$configured_pem" \
			--exclusions "$exclusion_file"
		validation_status=$?
		checked_pem_files[$configured_pem]=$validation_status
		if (( validation_status == 0 )); then
			logS "         Referenced PEM '$configured_pem' is valid."
		else
			logW "         Referenced PEM '$configured_pem' failed validation."
		fi
		return "$validation_status"
	}

	# Function to check if a file contains a specific variable
	contains_variable() {
	  local variable=$1 assignment configured_pem
	  assignment=$(grep -E "^[[:space:]]*export[[:space:]]+${variable}=" "$CONFIG_FILE" | tail -n 1)
	  if [[ -n "$assignment" ]]; then
	    logW "      ${GREENW}$variable${NC} was already set in the user's Shell Config file"
	    logI "          $assignment"
	    configured_pem=$(configured_pem_path "$assignment")
	    validate_configured_pem "$configured_pem"
	  else
	    if [[ -z ${overwrite-} ]]; then logI "      Adding ${GREENW}$variable${NC} was not set in $CONFIG_FILE. Let's add it..." ; fi
		print -r -- "export ${variable}=\"${customcacert}\"" >> "$CONFIG_FILE"
 		# Check again, if we were able to add the variable
		if grep -qE "^[[:space:]]*export[[:space:]]+${variable}=" "$CONFIG_FILE"; then
		    logS "         export ${GREENW}$variable${NC}=\"$customcacert\" has been added to the Shell config file..."
	    else
	    	logE "         $variable could not be added to $CONFIG_FILE! Aborting..."
	    fi
	  fi
	}

	# Iterate over each variable and check
	for var in "${variables[@]}"; do
	  contains_variable "$var" || shell_validation_status=1
	done
	return "$shell_validation_status"
}

# Download the latest cacert.pem from curl.se (It contains an updated list of Public Root CAs)
cacert_download() {
	if [[ -z ${HOME_DIR-} ]]; then source "$current_dir/../lib/user_config.sh"; fi
	customcacert="$HOME_DIR/.config/cacert/cacert.pem"
	local target_dir=$(dirname "$customcacert")
	mkdir -p "$target_dir" || return 1
	build_dir=$(mktemp -d "$target_dir/.cacert-build.XXXXXX") || return 1
	public_candidate="$build_dir/public.pem"
	custom_candidate="$build_dir/cacert.pem"

	logI " Downloading the current Mozilla root CA bundle from $cacertURL"
	local attempt download_ok=0
	for attempt in 1 2 3; do
		if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
			--output "$public_candidate" "$cacertURL"; then
			download_ok=1
			break
		fi
		logW "    Download failed on attempt $attempt."
	done
	if (( ! download_ok )); then
		rm -rf "$build_dir"
		logW "    The fresh CA bundle could not be downloaded; the existing bundle was left unchanged."
		return 1
	fi

	# The downloaded file is the authoritative public trust input. The completed
	# public + internal bundle is validated once, immediately before publication.
	cp "$public_candidate" "$custom_candidate" || { rm -rf "$build_dir"; return 1; }
}

publish_cacert() {
	local backup
	if [[ -f "$customcacert" ]]; then
		backup="$customcacert.$(date '+%F_%H%M%S').bak"
		cp -p "$customcacert" "$backup" || return 1
		# Retain the five newest recoverable backups.
		local -a backups
		backups=("$customcacert".*.bak(Nom))
		(( ${#backups[@]} > 5 )) && rm -f -- "${backups[@]:5}"
	fi

	mv -f "$public_candidate" "$customcacert.public" || return 1
	mv -f "$custom_candidate" "$customcacert" || return 1
	rmdir "$build_dir" 2>/dev/null || true
	logS "    Published a fresh validated certificate store at '$customcacert'."
}

###########################   Script Switches and Runtime   ###########################

extravar # Executing the function to find all Shell variables to set (or unset for that matter)


# Switches and Executions for the initial call (regardless of when)
while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h) help ;;								
    --uninstall|-u) uninstall ;;					# Wipe everything this script did: custom certificate store (cacert.pem) and restore original ~/.zshrc (pre-reuntime of this script)
	--download|-d) download_only=1 ;;				# Build the custom certificate store without touching shell variables.
	--daemon|-D) daemon ;;							# It will create a LaunchAgent in User Directory to periodically update the Custom Certificate so it remains up to date...
	--overwrite|-o) overwrite=true ; uninstall ;;	# It will force rewrite the cacert.pem + Env variables in user's Shell Config 
   *) ;;
  esac
  shift
done


# Execute the function to check web connectivity without SSL verification
echo; logI "  ---   ${PINK}SCRIPT: $current_dir/$scriptname${NC}   ---"
logI "        ${PINK}     This script will download a public Certificate Store and add Internal CAs to it${NC}"
logI "        ${PINK}     It will then create environment variable in the user shell config and reference it...${NC}"


source "$current_dir/../lib/user_config.sh" --quiet	# Let's identify the logged-in user, it's home directory, it's default Shell interpreter and associated config file...
cacert_download || logE "Unable to prepare a fresh public root CA bundle."

# List the Internal Root CAs and patch cacert.pem with internal Root CAs
source "$current_dir/Keychain_InternalCAs.sh" --silent		# This command will invoke the script and return variable $CAList which lists the names of Internal Signing Root CAs from the Keychain Access in MacOS
trustca "$custom_candidate" || { rm -rf "$build_dir"; logE "Unable to add internal root CAs."; }

# Validate the complete bundle against macOS Keychain trust and the local
# exclusion policy. The downloaded Mozilla bundle is input, not a trust override.
source "$current_dir/PEM_Check.sh" --quiet --cafile "$custom_candidate" \
	--exclusions "$exclusion_file"
if (( $? != 0 )); then
	rm -rf "$build_dir"
	logE "The completed certificate store failed validation."
fi
publish_cacert || { rm -rf "$build_dir"; logE "Unable to publish the validated certificate store."; }

# Let's inspect the file for existing environement variables & Let's reference this cacert.pem in the Shell Interpreter config file
if [[ -z "${download_only-}" ]]; then
	shell_var || logE "One or more PEM files referenced by shell variables failed validation."
fi

if [[ -z "${download_only-}" ]]; then source "$CONFIG_FILE"; fi
[[ -n "${script_dir-}" ]] && cd "$script_dir"
