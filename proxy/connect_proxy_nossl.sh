#!/bin/zsh
local scriptname=$(basename $(realpath $0))
local current_dir=$(dirname $(realpath $0))
if [[ -z ${teefile-} ]]; then source "$current_dir/../lib/stderr_stdout_syntax.sh"; fi
# CUSTOM_PAC_URL="http://pac.internal.com/org.pac"
if [[ -n $pac_url ]]; then CUSTOM_PAC_URL="$pac_url" ; fi

################################ VARIABLES #############################
# List of websites to check for webconn_checks()
AlpacaDaemon_path="$HOME/Library/LaunchAgents/homebrew.mxcl.alpaca.plist"
website_regex="^https:\/\/([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\/?$"
websites=("https://photonsec.com.au" "https://www.google.com")  # List of websites to check for check_website()
    # Read additional websites from the configuration file
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and lines starting with "#"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ $website_regex ]]; then websites+=("$line"); fi
    done < "$current_dir/websites.config"
local fail_count=0; local max_fail=4         # Counter for failed web connections for webconn_checks(), It'll stop checking after the first 10 websites
local curltimeout=3   # Number of seconds after which cURL will give up connecting for check_website()


################################ FUNCTIONS #############################


# Function to check if a website is reachable
check_website_withoutSSL() {
    url=$1
    logI "  Checking connection to $url"
    start_spinner "Please wait..."
    if curl -skI --connect-timeout $curltimeout --max-time $curltimeout "$url" | grep -E "HTTP/2 200|HTTP/1.1 200" > /dev/null; then
        echo -en "\r\033[2K\033[F\033[2K"
        stop_spinner; logI "  Connection via local proxy (Alpaca) ${GREEN}succeeded${NC}: $url"
        ((success_count++))
    else
        echo -en "\r\033[2K\033[F\033[2K"
        stop_spinner; logI "  Connection via local proxy (Alpaca) ${ORANGE}failed${NC}: $url"  
        ((fail_count++))
    fi
}

# Function to check web connectivity against multiple websites
webconn_checks() {
  unset proxy_not_working
  unset success_count
  unset fail_count
  logI "We'll now attempt to make a few web requests to test the local proxy..."
  logI "  The list of websites was supplied from $current_dir/${BLUEW}websites.config${NC}"
  logI "  Feel free (or not) to add your internal websites, or SSL inspected websites to this file for better accuracy"

  for site in "${websites[@]}"; do
    check_website_withoutSSL "$site"
    if [ "$fail_count" -ge "$max_fail" ]; then
      proxy_not_working=true
      break # It looks like the proxy is not working, no need to test all the websites...
    fi
  done
}

# Function to reload Alpaca Daemon
reload_alpaca_daemon() {
  start_spinner "Reloading Alpaca Daemon, please wait..."
  launchctl unload "$AlpacaDaemon_path"
  sleep 4
  launchctl load "$AlpacaDaemon_path"
  sleep 6
  stop_spinner
}

# Function to exit gracefully if running standalone
exit_if_standalone () {
  #If this script is running standalone, let's stop here...
  if [[ -z ${invoked_by_alpaca-} ]]; then exit 0; fi
}

################################ RUNTIME #############################

echo; logI "  ---   ${PINK}SCRIPT: $current_dir/$scriptname${NC}   ---"
logI "        ${PINK}     It is intended to check if connection can be established over the local proxy Alpaca${NC}"

if [[ -z ${HTTPS_PROXY-} || -z ${https_proxy-} ]]; then
  logW "Proxy settings were not set..."
fi

export ALL_PROXY="http://localhost:3128"
export all_proxy="http://localhost:3128"
export HTTP_PROXY="http://localhost:3128"
export http_proxy="http://localhost:3128"
export HTTPS_PROXY="http://localhost:3128"
export https_proxy="http://localhost:3128"
logI "The following proxy variables have been set:"
logI "    ${GREENW}http_proxy${NC}  is set to \"$http_proxy\"" 
logI "    ${GREENW}https_proxy${NC} is set to \"$https_proxy\""

# Check if HTTPS requests are getting throught the local proxy...

webconn_checks

# Test if we could connect or not...
if [[ -n $proxy_not_working ]]; then
      logW "    It looks like the proxy fails establishing connections..."
      exit_if_standalone 
      # Since Alpaca is running as a user daemon, let's inspect its LaunchAgent config, maybe it's missing the PAC URL...
      if [[ -f "$AlpacaDaemon_path" && -n $CUSTOM_PAC_URL ]]; then
          logI "      Let's inspect the config file in "$AlpacaDaemon_path"..."
          logI "      We're looking for $CUSTOM_PAC_URL entry..."
          if cat "$AlpacaDaemon_path" | grep -q "$CUSTOM_PAC_URL"; then
              logI "      PAC URL is already specified in the file!"
              logW "      Alpaca should work but isn't..."
              logE "Please uninstall and reinstall: ${BLUEW}./AlpacaSetup --uninstall${NC}"
          else
            if cat "$AlpacaDaemon_path" | grep -q '<string>-C</string>'; then
              logI "      Another PAC URL appears to be specified in the file!"
              logE "Please uninstall and reinstall to create this bad entry in the daemon: ${BLUEW}./AlpacaSetup --uninstall${NC}"
            else
              logW "      PAC URL is not specified in the file! Let's add it and test again..."
              sed -i '' '/<key>ProgramArguments<\/key>/,/<\/array>/ {
    /<string>[^<]*<\/string>/a\
        <string>-C<\/string>\
        <string>'"${CUSTOM_PAC_URL}"'<\/string>
}' "$AlpacaDaemon_path"
              reload_alpaca_daemon
              # Check AGAIN if HTTPS requests are getting throught...
              webconn_checks
            fi
          fi
      else
          logE "Please troubleshooting Alpaca proxy manually or uninstall it..."
      fi
fi

if [[ -z ${proxy_not_working-} ]]; then
  logS "    It looks like the local proxy can establish connections..."
elif [[ $success_count -gt $fail_count ]]; then
  logS "    It looks like the local proxy can establish connections..."
else
  logW "    It looks our local proxy is broken..."
  logE "Please troubleshooting Alpaca proxy manually or uninstall it..."
fi

