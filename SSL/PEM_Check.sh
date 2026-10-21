#!/bin/zsh

# Validate and, when authorised, clean a PEM root certificate bundle.

local scriptname=$(basename "$(realpath "$0")")
local current_dir=$(dirname "$(realpath "$0")")
local standalone=1
[[ "${ZSH_EVAL_CONTEXT-}" == *:file* || -n "${invoked-}" ]] && standalone=0

if [[ -z "${BLUEW-}" ]]; then
    source "$current_dir/../lib/stderr_stdout_syntax.sh"
    AppName="Pem_Integrity_Check"
    teefile="/tmp/$AppName.log"
fi

local exclusion_file="$current_dir/ca_exclusions.conf"
local audit_only=0
local verbose=0
local quiet=0
local pem_file=""
pem_error=false

help() {
    cat <<EOF
Usage: $scriptname [OPTIONS] [PEM_FILE]

Validate a PEM root CA bundle and identify certificates which are malformed,
expired, not yet valid, not signing root CAs, duplicated, untrusted by macOS,
or explicitly denied by the local CA exclusion policy.

Options:
  --cafile, -c, -f PATH       PEM bundle to inspect
  --exclusions PATH           CA exclusion policy (default: $exclusion_file)
  --audit                     Report issues without changing the PEM file
  --verbose, -v               List retained certificate subjects
  --quiet, -q                 Suppress progress and success messages
  --help, -h                  Show this help

When this script is executed directly, it explains every proposed removal and
requires confirmation before changing the file. When sourced by the bundle
builder, unsafe certificates are removed automatically.
EOF
}

normalise_hash() {
    print -r -- "$1" | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'
}

certificate_fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^.*=//' | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'
}

certificate_spki_hash() {
    openssl x509 -in "$1" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 2>/dev/null \
        | sed 's/^.*= //' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

certificate_name() {
    local name
    name=$(openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed 's/^subject=//')
    [[ -n "$name" ]] && print -r -- "$name" || print -r -- "certificate #$2"
}

# Print the policy reason if a certificate is explicitly excluded.
exclusion_reason() {
    local cert_sha="$1" spki_sha="$2"
    local kind value display reason normalised
    [[ -r "$exclusion_file" ]] || return 1

    while IFS='|' read -r kind value display reason || [[ -n "$kind$value$display$reason" ]]; do
        [[ -z "$kind" || "$kind" == \#* ]] && continue
        normalised=$(normalise_hash "$value")
        case "$kind" in
            cert_sha256)
                [[ "$cert_sha" == "$normalised" ]] || continue
                ;;
            spki_sha256)
                [[ "$spki_sha" == "$normalised" ]] || continue
                ;;
            *)
                continue
                ;;
        esac
        print -r -- "${reason:-Explicitly excluded by local policy}${display:+ ($display)}"
        return 0
    done < "$exclusion_file"
    return 1
}

show_exclusion_policy() {
    local kind value display reason normalised count=0
    if [[ ! -r "$exclusion_file" ]]; then
        logW "Local exclusion policy '$exclusion_file' is not readable."
        return 1
    fi

    logI "Configured local CA exclusions:"
    while IFS='|' read -r kind value display reason || [[ -n "$kind$value$display$reason" ]]; do
        [[ -z "$kind" || "$kind" == \#* ]] && continue
        [[ "$kind" == cert_sha256 || "$kind" == spki_sha256 ]] || continue
        normalised=$(normalise_hash "$value")
        count=$((count + 1))
        logI "  $display [$kind: $normalised]"$'\n'"                            $reason"
    done < "$exclusion_file"
    (( count > 0 )) || logI "  (none)"
}

macos_trusts_certificate() {
    command -v security >/dev/null 2>&1 || return 127
    # -L avoids fetching issuer material. Apple trust metadata and local
    # Keychain trust settings are still consulted.
    security verify-cert -c "$1" -l -L -q >/dev/null 2>&1
}

rewrite_bundle() {
    local source_file="$1" temp_dir="$2" count="$3"
    local replacement="${source_file}.clean.$$" index cert

    : > "$replacement" || return 1
    print -r -- "# Root CA bundle validated by $scriptname on $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$replacement"
    print -r -- "# Exclusion policy: $exclusion_file" >> "$replacement"

    for (( index=1; index<=count; index++ )); do
        [[ -n "${remove_reasons[$index]-}" ]] && continue
        cert=$(printf '%s/cert_%06d.pem' "$temp_dir" "$index")
        print >> "$replacement"
        cat "$cert" >> "$replacement" || {
            rm -f "$replacement"
            return 1
        }
    done

    chmod --reference="$source_file" "$replacement" 2>/dev/null || chmod 0644 "$replacement"
    mv -f "$replacement" "$source_file"
}

pem_integrity_check() {
    local target="$1"
    local temp_dir count_file count=0 begin_count end_count index cert
    local name cert_sha spki_sha reason subject issuer constraints key_usage
    local retained=0 trust_status policy_match_count=0
    typeset -gA remove_reasons seen_fingerprints
    remove_reasons=()
    seen_fingerprints=()
    cert_CNs=""

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pem-check.XXXXXX") || return 1
    count_file="$temp_dir/count"

    begin_count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$target" 2>/dev/null)
    end_count=$(grep -c -- '-----END CERTIFICATE-----' "$target" 2>/dev/null)
    if grep -Eq -- '-----BEGIN (.*PRIVATE KEY|.*CERTIFICATE REQUEST)-----' "$target"; then
        logW "Private keys or certificate requests were found in '$target'; the file was not changed."
        rm -rf "$temp_dir"
        pem_error=true
        return 1
    fi
    if (( begin_count == 0 || begin_count != end_count )); then
        logW "Certificate boundaries in '$target' are missing or unbalanced; the file was not changed."
        rm -rf "$temp_dir"
        pem_error=true
        return 1
    fi

    awk -v dir="$temp_dir" '
        /-----BEGIN CERTIFICATE-----/ {
            if (in_cert) malformed=1
            in_cert=1; count++
            file=sprintf("%s/cert_%06d.pem", dir, count)
        }
        in_cert { print > file }
        /-----END CERTIFICATE-----/ && in_cert { close(file); in_cert=0 }
        END {
            if (in_cert) malformed=1
            print count+0 > (dir "/count")
            exit malformed ? 2 : 0
        }
    ' "$target"
    if (( $? != 0 )); then
        logW "Nested or incomplete PEM certificate blocks were found; the file was not changed."
        rm -rf "$temp_dir"
        pem_error=true
        return 1
    fi
    count=$(<"$count_file")
    (( quiet )) || logI "Inspecting $count certificates in '$target'."
    (( verbose )) && show_exclusion_policy

    for (( index=1; index<=count; index++ )); do
        cert=$(printf '%s/cert_%06d.pem' "$temp_dir" "$index")
        name=$(certificate_name "$cert" "$index")

        if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
            remove_reasons[$index]="Malformed certificate data"
            continue
        fi

        cert_sha=$(certificate_fingerprint "$cert")
        spki_sha=$(certificate_spki_hash "$cert")
        if reason=$(exclusion_reason "$cert_sha" "$spki_sha"); then
            policy_match_count=$((policy_match_count + 1))
            remove_reasons[$index]="Explicitly distrusted/revoked by policy: $reason"
            continue
        fi

        if [[ -n "${seen_fingerprints[$cert_sha]-}" ]]; then
            remove_reasons[$index]="Duplicate of certificate #${seen_fingerprints[$cert_sha]}"
            continue
        fi
        seen_fingerprints[$cert_sha]=$index

        if ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
            remove_reasons[$index]="Expired at $(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
            continue
        fi

        subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
        issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
        if [[ "$subject" != "$issuer" ]]; then
            remove_reasons[$index]="Not a self-signed root CA"
            continue
        fi

        constraints=$(openssl x509 -in "$cert" -noout -ext basicConstraints 2>/dev/null)
        if [[ "$constraints" != *"CA:TRUE"* ]]; then
            remove_reasons[$index]="Basic Constraints does not permit CA signing"
            continue
        fi

        key_usage=$(openssl x509 -in "$cert" -noout -ext keyUsage 2>/dev/null)
        if [[ -n "$key_usage" && "$key_usage" != *"Certificate Sign"* ]]; then
            remove_reasons[$index]="Key Usage does not permit certificate signing"
            continue
        fi

        # Verifying the root against itself checks its signature and validity,
        # including a notBefore date in the future.
        if ! openssl verify -check_ss_sig -CAfile "$cert" "$cert" >/dev/null 2>&1; then
            remove_reasons[$index]="Self-signature is invalid or the certificate is not yet valid"
            continue
        fi

        macos_trusts_certificate "$cert"
        trust_status=$?
        if (( trust_status == 127 )); then
            remove_reasons[$index]="Trust cannot be established because the macOS security tool is unavailable"
            continue
        elif (( trust_status != 0 )); then
            remove_reasons[$index]="Not trusted as a root CA by the current macOS Keychain trust settings"
            continue
        fi

        retained=$((retained + 1))
        (( verbose )) && cert_CNs+="$index) $name"$'\n'
    done

    if (( policy_match_count > 0 )); then
        logW "Local exclusion policy '$exclusion_file' matched $policy_match_count certificate(s)."
    elif (( verbose )); then
        logI "No explicitly excluded certificates are present in '$target'."
    fi

    local -a removal_indexes
    removal_indexes=(${(kon)remove_reasons})
    if (( ${#removal_indexes[@]} > 0 )); then
        pem_error=true
        logW "The following certificates should be removed from '$target':"
        for index in "${removal_indexes[@]}"; do
            cert=$(printf '%s/cert_%06d.pem' "$temp_dir" "$index")
            name=$(certificate_name "$cert" "$index")
            logW "  #$index $name — ${remove_reasons[$index]}"
        done

        if (( retained == 0 )); then
            logW "Removal would leave no trusted root CAs; the file was not changed."
        elif (( audit_only )); then
            logW "Audit mode is enabled; no certificates were removed."
        elif (( standalone )); then
            if [[ -t 0 ]]; then
                local reply
                print -n -- "Remove these ${#removal_indexes[@]} certificate(s) from the PEM file? [y/N] "
                read -r reply
                if [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]; then
                    rewrite_bundle "$target" "$temp_dir" "$count" || {
                        logW "Unable to replace '$target' with the cleaned bundle."
                        rm -rf "$temp_dir"
                        return 1
                    }
                    logS "Removed ${#removal_indexes[@]} unsafe certificate(s); $retained trusted root CA(s) remain."
                    pem_error=false
                else
                    logW "No certificates were removed."
                fi
            else
                logW "Confirmation requires an interactive terminal; no certificates were removed."
            fi
        else
            rewrite_bundle "$target" "$temp_dir" "$count" || {
                logW "Unable to replace '$target' with the cleaned bundle."
                rm -rf "$temp_dir"
                return 1
            }
            logI "Removed ${#removal_indexes[@]} unsafe certificate(s); $retained trusted root CA(s) remain."
            pem_error=false
        fi
    else
        pem_error=false
        (( quiet )) || logS "Certificate store contains $retained valid, trusted root signing CA(s)."
    fi

    (( verbose )) && print -r -- "$cert_CNs"
    rm -rf "$temp_dir"
    [[ "$pem_error" == false ]]
}

while (( $# > 0 )); do
    case "$1" in
        --verbose|-v) verbose=1; shift ;;
        --quiet|-q) quiet=1; shift ;;
        --audit) audit_only=1; shift ;;
        --exclusions)
            [[ $# -ge 2 ]] || { print -u2 -- "Missing value for $1"; return 2 2>/dev/null || exit 2; }
            exclusion_file="$2"; shift 2 ;;
        --cafile|-c|-f)
            [[ $# -ge 2 ]] || { print -u2 -- "Missing value for $1"; return 2 2>/dev/null || exit 2; }
            pem_file="$2"; shift 2 ;;
        --help|-h)
            help
            if (( standalone )); then exit 0; else return 0; fi
            ;;
        --*)
            print -u2 -- "Unknown option: $1"
            help
            if (( standalone )); then exit 2; else return 2; fi
            ;;
        *)
            [[ -z "$pem_file" ]] || { print -u2 -- "Only one PEM file may be supplied."; return 2 2>/dev/null || exit 2; }
            pem_file="$1"; shift ;;
    esac
done

if [[ -z "$pem_file" ]]; then
    if (( standalone )) && [[ -t 0 ]]; then
        print -n -- "PEM file to inspect: "
        read -r pem_file
    else
        logW "A PEM file is required."
        return 2 2>/dev/null || exit 2
    fi
fi

if [[ ! -f "$pem_file" ]]; then
    logW "File '$pem_file' was not found."
    if (( standalone )); then exit 1; else return 1; fi
fi
if [[ ! -r "$exclusion_file" ]]; then
    logW "CA exclusion policy '$exclusion_file' is not readable; validation cannot continue safely."
    if (( standalone )); then exit 1; else return 1; fi
fi
(( quiet )) || {
    print
    logI "--- SCRIPT: $current_dir/$scriptname ---"
    logI "Validating root CA structure, dates, trust and local exclusion policy."
}

pem_integrity_check "$pem_file"
local result=$?
if (( standalone )); then exit "$result"; else return "$result"; fi
