#!/bin/zsh
local scriptname=$(basename $(realpath $0))
local current_dir=$(dirname $(realpath $0))
if [[ -z ${logI-} ]]; then source "$current_dir/../lib/stderr_stdout_syntax.sh"; fi


###################################### FUNCTIONS ##########################################

# Function to get and process HTTP proxy settings for a given network service
get_proxy_settings() {
    local service=$1
    local webproxy_settings securewebproxy_settings autoproxy_settings
    local proxy_server proxy_port pac_url_for_service
    logI "    Proxy settings for $service"

    # Fetch web proxy settings
    webproxy_settings=$(networksetup -getwebproxy "${service}")
    if echo "$webproxy_settings" | grep -q "Enabled: Yes"; then
        proxy_server=$(print -r -- "$webproxy_settings" | awk -F': ' '/^Server:/{print $2}')
        proxy_port=$(print -r -- "$webproxy_settings" | awk -F': ' '/^Port:/{print $2}')
        logI "      HTTP proxy enabled: ${proxy_server:-unknown}:${proxy_port:-unknown}"
    else unset webproxy_settings
    fi

    # Fetch secure web proxy settings
    securewebproxy_settings=$(networksetup -getsecurewebproxy "${service}")
    if echo "$securewebproxy_settings" | grep -q "Enabled: Yes"; then
        proxy_server=$(print -r -- "$securewebproxy_settings" | awk -F': ' '/^Server:/{print $2}')
        proxy_port=$(print -r -- "$securewebproxy_settings" | awk -F': ' '/^Port:/{print $2}')
        logI "      HTTPS proxy enabled: ${proxy_server:-unknown}:${proxy_port:-unknown}"
    else unset securewebproxy_settings
    fi

    # Fetch auto proxy settings
    autoproxy_settings=$(networksetup -getautoproxyurl "${service}")
    if echo "$autoproxy_settings" | grep -q "Enabled: Yes"; then
        pac_url_for_service=$(print -r -- "$autoproxy_settings" | awk -F': ' '/^URL:/{print $2}')
        [[ -n "$pac_url_for_service" ]] && pac_urls+=("$pac_url_for_service")
        logI "      Auto proxy URL enabled: ${pac_url_for_service:-unknown}"
    else unset autoproxy_settings
    fi

    if [[ -z "${webproxy_settings-}" && -z "${securewebproxy_settings-}" && -z "${autoproxy_settings-}"  ]]; then
        logI "    No Pac file URL found for $service"
    fi
}

###################################### RUNTIME ##########################################
echo; logI "  ---   ${PINK}SCRIPT: $current_dir/$scriptname${NC}   ---"
logI "        ${PINK}     This script is intended to verify network connectivity and whether a PAC file can be found${NC}"

# Fetch all network services, excluding the first line
interfaces=$(networksetup -listallnetworkservices | tail -n +2)

# Iterate over each network service and fetch HTTP proxy settings
logI "Inspecting NICs..."
while IFS= read -r service; do
    IPAddr=$(networksetup -getinfo "$service" | grep -E '^IP address: ((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')
    if [[ -n $IPAddr ]]; then
        logS  "   $service is active  //  $IPAddr"
        activeIP=true
        get_proxy_settings "${service}"
    else
        logW "   $service is inactive, it doesn't have an IP address or a valid one..."
        get_proxy_settings "${service}"
    fi
    
done <<< "$interfaces"

if [[ -z ${activeIP-} ]]; then
    logE "There are no interfaces with a valid IP address, you're either disconnected or with a APIPA issue... Aborting!"
else
    # Fetch scutil proxy settings as well...
    scutil_proxy_info=$(scutil --proxy)
    scutil_proxy_url=$(echo "$scutil_proxy_info" | grep 'ProxyAutoConfigURLString' | awk '{print $3}')
    logI "Looking for proxy PAC (Proxy Auto-Configuration) File from \`scutil --proxy\` ..."
    if [[ -n "$scutil_proxy_url" ]]; then
        pac_urls+=("$scutil_proxy_url")
        logI "    Pac file URL found: $scutil_proxy_url"
    else logI "   No Pac file URL found from scutil command..."
    fi
fi

# Check if any proxy URL was found
if [[ ${#pac_urls[@]} -eq 0 ]]; then
    logW "PAC file URL could not be found"
else
    # Remove duplicate URLs and then display unique URLs
    proxy_urls=($(echo "${pac_urls[@]}" | tr ' ' '\n' | sort -u))
    logI "We have found the following PAC file URL(s):"
    # Test each PAC URL to check if the file exists
    for url in "${proxy_urls[@]}"; do
        if curl --head --silent --fail "$url" > /dev/null; then
            logS "    Testing PAC file URL: $url... It can be downloaded!"
            pac_url="$url"      # We set this variable for the other script to know we have a pac file
        else
            logW "    Testing PAC file URL: $url... It cannot be read!"
        fi
    done
fi
