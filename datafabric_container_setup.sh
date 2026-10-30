#!/bin/bash
#set -x
IMAGE="maprtech/edf-seed-container:latest"
INTERFACE="en0"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage()
{
   echo "This script will deploy HPE DataFabric on a seed node."
   echo
   echo "Syntax: ./datafabric_container_setup.sh [-i|--image] [-p|--publicipv4dns] [-f|--proxyfiledetails] [--legacy-docker-install]"
   echo "options:"
   echo "-i|--image this is optional. By default it will pull the image with the latest tag,
         we can also provide an image which has a custom tag example:maprtech/edf-seed-container:7.4.0_9.1.2"
   echo "-p|--publicipv4dns is the public IPv4 DNS and needed for cloud-deployed seed nodes. Note that both inbound and outbound traffic on port 8443
         needs to be enabled on the cloud instance. Otherwise, the Data Fabric UI cannot be accessed"
   echo "-f|--proxyfiledetails is the location of the file from where proxy details provided by the user are copied to the docker container."
   echo "-l|--local use a locally built image, skip docker pull"
   echo "--legacy-docker-install use the manual Ubuntu Docker APT installation path"
   echo
}

os_name=$(. /etc/os-release  2> /dev/null && echo "$ID") &> /dev/null
os_vers=`uname -s` > /dev/null 2>&1

# Inspect installation selection without consuming arguments used by the later parser.
legacy_docker_install=false
docker_option_value=false
for docker_option in "$@"; do
    if [ "$docker_option_value" = true ]; then
        docker_option_value=false
        continue
    fi
    case "$docker_option" in
        -i|--image|-p|--publicipv4dns|-f|--proxyfiledetails|-r|--repo_url)
            docker_option_value=true ;;
        --legacy-docker-install) legacy_docker_install=true ;;
        -l|--local) ;;
        *) break ;;
    esac
done

escape_systemd_environment_value()
{
    local escaped_value="$1"

    case "$escaped_value" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac

    escaped_value="${escaped_value//\\/\\\\}"
    escaped_value="${escaped_value//\"/\\\"}"
    escaped_value="${escaped_value//%/%%}"
    printf '%s' "$escaped_value"
}

docker_service_diagnostics()
{
    {
        systemctl status docker --no-pager --full --lines=20
        journalctl -u docker --no-pager -n 40
    } 2>&1 | sed -E \
        -e '/[Pp][Rr][Oo][Xx][Yy]/c\[proxy-related diagnostic redacted]' \
        -e 's#(https?://)[^/[:space:]]*@#\1[redacted]@#g' >&2
    return 0
}

install_docker_linux()
{
    local docker_ready
    local docker_ready_attempt
    local docker_architecture
    local ubuntu_codename
    local docker_http_proxy
    local docker_https_proxy
    local docker_no_proxy
    local escaped_http_proxy
    local escaped_https_proxy
    local escaped_no_proxy
    local docker_service_action="start"
    local -a key_status

    echo "Docker is not present on the system. Installing it..."
    echo "Docker installation may take 6 to 8 minutes."
    echo "There is no input/intervention required from the user."

    if [ $os_name == "ubuntu" ]; then
        if [ "${legacy_docker_install:-false}" = true ]; then
            sudo apt-get update > /dev/null || {
                echo "Failed to update Ubuntu package indexes for Docker." >&2
                return 1
            }
            sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
                apt-get -y install ca-certificates curl gnupg > /dev/null || {
                echo "Failed to install Docker repository prerequisites." >&2
                return 1
            }
            sudo install -m 0755 -d /etc/apt/keyrings || {
                echo "Failed to create the Docker APT keyring directory." >&2
                return 1
            }
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
            key_status=("${PIPESTATUS[@]}")
            if [ "${key_status[0]}" -ne 0 ] || [ "${key_status[1]}" -ne 0 ]; then
                echo "Failed to install the Docker repository signing key." >&2
                return 1
            fi
            sudo chmod a+r /etc/apt/keyrings/docker.gpg || {
                echo "Failed to make the Docker repository signing key readable." >&2
                return 1
            }
            docker_architecture=$(dpkg --print-architecture) || {
                echo "Failed to determine the Ubuntu package architecture." >&2
                return 1
            }
            ubuntu_codename=$(. /etc/os-release && echo "$VERSION_CODENAME") || {
                echo "Failed to determine the Ubuntu release codename." >&2
                return 1
            }
            echo \
              "deb [arch=${docker_architecture} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                ${ubuntu_codename} stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || {
                echo "Failed to configure the Docker APT repository." >&2
                return 1
            }

            sudo apt-get update > /dev/null || {
                echo "Failed to update package indexes for the Docker repository." >&2
                return 1
            }
            sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null || {
                echo "Failed to install Docker packages." >&2
                return 1
            }
        else
            docker_install_dir=$(mktemp -d "${TMPDIR:-/tmp}/datafabric-docker-install.XXXXXX") || {
                echo "Failed to create temporary files for the Docker installer." >&2
                return 1
            }
            curl -fsSL https://get.docker.com -o "$docker_install_dir/install.sh" || {
                echo "Failed to download the official Docker installer. See https://docs.docker.com/engine/install/" >&2
                rm -rf -- "$docker_install_dir"
                return 1
            }
            sh "$docker_install_dir/install.sh" --no-autostart || {
                echo "Docker installer failed. Review the installer output immediately above. See https://docs.docker.com/engine/install/" >&2
                rm -rf -- "$docker_install_dir"
                return 1
            }
            rm -rf -- "$docker_install_dir"
        fi

        docker_http_proxy="${HTTP_PROXY:-${http_proxy:-}}"
        docker_https_proxy="${HTTPS_PROXY:-${https_proxy:-}}"
        docker_no_proxy="${NO_PROXY:-${no_proxy:-}}"

        if [ -n "$docker_http_proxy" ] || [ -n "$docker_https_proxy" ]; then
            escaped_http_proxy=$(escape_systemd_environment_value "$docker_http_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            escaped_https_proxy=$(escape_systemd_environment_value "$docker_https_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            escaped_no_proxy=$(escape_systemd_environment_value "$docker_no_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            sudo install -m 0755 -d /etc/systemd/system/docker.service.d || {
                echo "Failed to create the Docker systemd drop-in directory." >&2
                return 1
            }

            if ! {
                printf '%s\n' '[Service]'
                if [ -n "$docker_http_proxy" ]; then
                    printf 'Environment="HTTP_PROXY=%s"\n' "$escaped_http_proxy"
                fi
                if [ -n "$docker_https_proxy" ]; then
                    printf 'Environment="HTTPS_PROXY=%s"\n' "$escaped_https_proxy"
                fi
                printf 'Environment="NO_PROXY=%s"\n' "$escaped_no_proxy"
            } | sudo tee /etc/systemd/system/docker.service.d/10-datafabric-proxy.conf > /dev/null; then
                echo "Failed to write the Docker systemd proxy drop-in." >&2
                return 1
            fi
        fi

        if ! systemctl daemon-reload > /dev/null; then
            echo "Failed to reload Docker systemd configuration." >&2
            return 1
        fi
        if ! systemctl enable docker > /dev/null; then
            echo "Docker was installed, but the service could not be enabled." >&2
            return 1
        fi
        docker_service_action="restart"
    elif [ $os_name == "rhel" ]; then
        if command -v docker > /dev/null 2>&1; then
            echo "Docker is installed, but unavailable or not running. Refusing to reinstall Docker." >&2
            return 1
        fi

        docker_install_dir=$(mktemp -d "${TMPDIR:-/tmp}/datafabric-docker-install.XXXXXX") || {
            echo "Failed to create temporary files for the Docker installer." >&2
            return 1
        }

        curl -fsSL https://get.docker.com \
            -o "$docker_install_dir/install.sh" || {
            echo "Failed to download the official Docker installer." >&2
            echo "See https://docs.docker.com/engine/install/" >&2
            rm -rf -- "$docker_install_dir"
            return 1
        }

        curl -fsSL https://download.docker.com/linux/rhel/gpg \
            -o "$docker_install_dir/docker.gpg" || {
            echo "Failed to download the Docker RHEL signing key." >&2
            rm -rf -- "$docker_install_dir"
            return 1
        }

        docker_key_info=$(gpg --batch --no-options --homedir "$docker_install_dir" \
            --with-colons --show-keys "$docker_install_dir/docker.gpg") || {
            echo "Failed to inspect the Docker RHEL signing key fingerprint." >&2
            rm -rf -- "$docker_install_dir"
            return 1
        }

        # Check every primary key; signing subkeys have their own fingerprints.
        # https://docs.docker.com/engine/install/rhel/
        docker_key_fingerprint=$(printf '%s\n' "$docker_key_info" | \
            awk -F: '$1 == "pub" { primary = 1 } $1 == "fpr" && primary { print $10; primary = 0 }')

        if [ "$docker_key_fingerprint" != "060A61C51B558A7F742B77AAC52FEB6B621E9F35" ]; then
            echo "Docker RHEL signing key fingerprint mismatch; refusing to import it." >&2
            rm -rf -- "$docker_install_dir"
            return 1
        fi

        rpm --import "$docker_install_dir/docker.gpg" || {
            echo "Failed to import the verified Docker RHEL signing key." >&2
            rm -rf -- "$docker_install_dir"
            return 1
        }

        sh "$docker_install_dir/install.sh" --no-autostart || {
            echo "Docker installer failed." >&2
            echo "Review the installer output immediately above. See https://docs.docker.com/engine/install/" >&2
            rm -rf -- "$docker_install_dir"
            return 1
        }

        rm -rf -- "$docker_install_dir"

        docker_http_proxy="${HTTP_PROXY:-${http_proxy:-}}"
        docker_https_proxy="${HTTPS_PROXY:-${https_proxy:-}}"
        docker_no_proxy="${NO_PROXY:-${no_proxy:-}}"

        if [ -n "$docker_http_proxy" ] || [ -n "$docker_https_proxy" ]; then
            escaped_http_proxy=$(escape_systemd_environment_value "$docker_http_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }

            escaped_https_proxy=$(escape_systemd_environment_value "$docker_https_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }

            escaped_no_proxy=$(escape_systemd_environment_value "$docker_no_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }

            install -m 0755 -d /etc/systemd/system/docker.service.d || {
                echo "Failed to create the Docker systemd drop-in directory." >&2
                return 1
            }

            if ! {
                printf '%s\n' '[Service]'

                if [ -n "$docker_http_proxy" ]; then
                    printf 'Environment="HTTP_PROXY=%s"\n' "$escaped_http_proxy"
                fi

                if [ -n "$docker_https_proxy" ]; then
                    printf 'Environment="HTTPS_PROXY=%s"\n' "$escaped_https_proxy"
                fi

                printf 'Environment="NO_PROXY=%s"\n' "$escaped_no_proxy"
            } | tee /etc/systemd/system/docker.service.d/10-datafabric-proxy.conf > /dev/null; then
                echo "Failed to write the Docker systemd proxy drop-in." >&2
                return 1
            fi

            if ! systemctl daemon-reload > /dev/null; then
                echo "Failed to reload Docker systemd configuration." >&2
                return 1
            fi
        fi
    elif [ $os_name == "sles" ]; then
        sudo zypper --non-interactive install docker || {
            echo "Failed to install Docker. The SUSE Containers Module/package repository must provide docker." >&2
            echo "See https://documentation.suse.com/container/all/single-html/Container-guide/#sec-docker-installation" >&2
            return 1
        }

        docker_http_proxy="${HTTP_PROXY:-${http_proxy:-}}"
        docker_https_proxy="${HTTPS_PROXY:-${https_proxy:-}}"
        docker_no_proxy="${NO_PROXY:-${no_proxy:-}}"

        if [ -n "$docker_http_proxy" ] || [ -n "$docker_https_proxy" ]; then
            escaped_http_proxy=$(escape_systemd_environment_value "$docker_http_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            escaped_https_proxy=$(escape_systemd_environment_value "$docker_https_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            escaped_no_proxy=$(escape_systemd_environment_value "$docker_no_proxy") || {
                echo "Docker proxy values must not contain newlines." >&2
                return 1
            }
            sudo install -m 0755 -d /etc/systemd/system/docker.service.d || {
                echo "Failed to create the Docker systemd drop-in directory." >&2
                return 1
            }

            if ! {
                printf '%s\n' '[Service]'
                if [ -n "$docker_http_proxy" ]; then
                    printf 'Environment="HTTP_PROXY=%s"\n' "$escaped_http_proxy"
                fi
                if [ -n "$docker_https_proxy" ]; then
                    printf 'Environment="HTTPS_PROXY=%s"\n' "$escaped_https_proxy"
                fi
                printf 'Environment="NO_PROXY=%s"\n' "$escaped_no_proxy"
            } | sudo tee /etc/systemd/system/docker.service.d/10-datafabric-proxy.conf > /dev/null; then
                echo "Failed to write the Docker systemd proxy drop-in." >&2
                return 1
            fi
        fi

        if ! systemctl daemon-reload > /dev/null; then
            echo "Failed to reload Docker systemd configuration." >&2
            return 1
        fi
        if ! systemctl enable docker > /dev/null; then
            echo "Docker was installed, but the service could not be enabled." >&2
            return 1
        fi
    elif [ $os_name == "centos" ]; then
       sudo yum install -y yum-utils > /dev/null
       sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
       sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    if ! systemctl "$docker_service_action" docker > /dev/null; then
        echo
        echo "Docker was installed, but the Docker service failed to start." >&2
        docker_service_diagnostics
        return 1
    fi

    docker_ready=0

    for docker_ready_attempt in {1..16}; do
        if docker info > /dev/null 2>&1; then
            docker_ready=1
            break
        fi

        if [ "$docker_ready_attempt" -lt 16 ]; then
            sleep 2
        fi
    done

    if [ "$docker_ready" -ne 1 ]; then
        echo
        echo "Docker service was started, but the Docker daemon did not become ready within 30 seconds." >&2
        docker info > /dev/null
        docker_service_diagnostics
        return 1
    fi

}

verify_container_engine()
{
    local engine="$1"

    if ! "$engine" info > /dev/null; then
        echo -e "${RED}$engine is installed, but the daemon is not running or not responding.${NC}" >&2
        return 1
    fi

    if ! "$engine" pull hello-world; then
        echo -e "${RED}$engine is running, but the hello-world image could not be pulled.${NC}" >&2
        echo -e "${RED}Please check registry connectivity, Docker Hub access, and proxy configuration.${NC}" >&2
        echo "See https://docs.docker.com/engine/daemon/proxy/" >&2
        return 1
    fi

    if ! "$engine" run hello-world > /dev/null; then
        echo -e "${RED}$engine successfully pulled the image, but failed to run the hello-world container.${NC}" >&2
        return 1
    fi
}

append_environment_file()
{
    local source_file="$1"
    local environment_file="$2"
    local normalized_file
    local line
    local line_number=0

    normalized_file=$(mktemp "${TMPDIR:-/tmp}/datafabric-environment.XXXXXX") || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$normalized_file"
        elif [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([[:alpha:]_][[:alnum:]_]*)[[:space:]]*=(.*)$ ]]; then
            printf '%s=%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >> "$normalized_file"
        else
            echo "Unsupported environment syntax in ${source_file} at line ${line_number}." >&2
            rm -f "$normalized_file"
            return 1
        fi
    done < "$source_file" || {
        rm -f "$normalized_file"
        return 1
    }

    if ! cat "$normalized_file" >> "$environment_file"; then
        rm -f "$normalized_file"
        return 1
    fi
    rm -f "$normalized_file"
}

append_proxy_environment_file()
{
    local source_file="$1"
    local environment_file="$2"
    local normalized_file
    local profile_file="${3:-}"
    local normalized_profile=""
    local profile_value
    local line
    local line_number=0
    local name
    local value

    normalized_file=$(mktemp "${TMPDIR:-/tmp}/datafabric-proxy-environment.XXXXXX") || return 1

    if [ -n "$profile_file" ]; then
        normalized_profile=$(mktemp "${TMPDIR:-/tmp}/datafabric-proxy-profile.XXXXXX") || {
            rm -f "$normalized_file" "${normalized_profile:-}"
            return 1
        }
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([[:alpha:]_][[:alnum:]_]*)[[:space:]]*=(.*)$ ]]; then
            name="${BASH_REMATCH[2]}"
            value="${BASH_REMATCH[3]}"
            case "$name" in
                ftp_proxy|http_proxy|https_proxy|FTP_PROXY|HTTP_PROXY|HTTPS_PROXY) ;;
                no_proxy|NO_PROXY)
                    if [[ "$value" =~ \$[[:alpha:]_][[:alnum:]_]* ]] ||
                       [[ "$value" =~ \$\{[[:alpha:]_][[:alnum:]_]*\} ]]; then
                        if ! value=$(printenv "$name"); then
                            echo "Unable to resolve ${name} from the process environment for ${source_file} at line ${line_number}." >&2
                            rm -f "$normalized_file" "${normalized_profile:-}"
                            return 1
                        fi
                        if [[ "$value" =~ \$[[:alpha:]_][[:alnum:]_]* ]] ||
                           [[ "$value" =~ \$\{[[:alpha:]_][[:alnum:]_]*\} ]]; then
                            echo "Resolved ${name} still contains shell variable references for ${source_file} at line ${line_number}." >&2
                            rm -f "$normalized_file" "${normalized_profile:-}"
                            return 1
                        fi
                    fi
                    ;;
                *) continue ;;
            esac
            if [ -n "$profile_file" ]; then
                # Strip only enclosing quotes; this is assignment parsing, not shell evaluation.
                profile_value="${value#"${value%%[![:space:]]*}"}"
                profile_value="${profile_value%"${profile_value##*[![:space:]]}"}"
                if [ "${#profile_value}" -ge 2 ] &&
                   { [[ "$profile_value" == \"*\" ]] || [[ "$profile_value" == \'*\' ]]; }; then
                    profile_value="${profile_value:1:${#profile_value}-2}"
                fi
                profile_value="${profile_value//\'/\'\\\'\'}"
                printf "export %s='%s'\n" "$name" "$profile_value" >> "$normalized_profile" || {
                    rm -f "$normalized_file" "$normalized_profile"
                    return 1
                }
            fi
            printf '%s=%s\n' "$name" "$value" >> "$normalized_file" || {
                rm -f "$normalized_file" "${normalized_profile:-}"
                return 1
            }
        fi
    done < "$source_file" || {
        rm -f "$normalized_file" "${normalized_profile:-}"
        return 1
    }

    if [ -n "$profile_file" ] && ! cat "$normalized_profile" >> "$profile_file"; then
        rm -f "$normalized_file" "$normalized_profile"
        return 1
    fi
    if ! cat "$normalized_file" >> "$environment_file"; then
        rm -f "$normalized_file" "${normalized_profile:-}"
        return 1
    fi
    rm -f "$normalized_file" "${normalized_profile:-}"
}

merge_proxy_profile()
{
    local host_profile="$1"
    local container_profile="${2:-/etc/profile.d/proxy.sh}"

    [ -f "$host_profile" ] || return 0
    $container_engine exec -i "$CID" bash -c '
profile=$1
mkdir -p "$(dirname "$profile")" || exit 1
if [ -s "$profile" ] && [ -n "$(tail -c 1 "$profile")" ]; then
    printf "\n" >> "$profile" || exit 1
fi
cat >> "$profile"
' _ "$container_profile" < "$host_profile"
}

normalize_noproxy_files() {
    local environment_file="$1"
    local profile_file="$2"
    local host_name="$3"
    local short_host_name="$4"
    local container_ip="${5:-}"
    local current_no_proxy
    local lower_no_proxy=""
    local upper_no_proxy=""
    local lower_found=0
    local normalized_no_proxy=""
    local entry
    local line
    local target_file
    local export_prefix
    local trimmed_entry
    local -a no_proxy_entries

    if [ ! -f "$environment_file" ] || \
       [ -z "$host_name" ] || \
       [ -z "$short_host_name" ] || \
       [ -z "$container_ip" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$profile_file")" || return 1
    touch "$profile_file" || return 1

    for target_file in "$environment_file" "$profile_file"; do
        lower_no_proxy=""
        upper_no_proxy=""
        lower_found=0
        normalized_no_proxy=""
        no_proxy_entries=()

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?no_proxy[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                lower_no_proxy="${BASH_REMATCH[2]}"
                lower_found=1
            elif [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?NO_PROXY[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                upper_no_proxy="${BASH_REMATCH[2]}"
            fi
        done < "$target_file" || return 1

        if [ "$lower_found" -eq 1 ]; then
            current_no_proxy="$lower_no_proxy"
        else
            current_no_proxy="$upper_no_proxy"
        fi
        current_no_proxy="${current_no_proxy#"${current_no_proxy%%[![:space:]]*}"}"
        current_no_proxy="${current_no_proxy%"${current_no_proxy##*[![:space:]]}"}"
        if [ "${#current_no_proxy}" -ge 2 ] &&
           { [[ "$current_no_proxy" == \"*\" ]] || [[ "$current_no_proxy" == \'*\' ]]; }; then
            current_no_proxy="${current_no_proxy:1:${#current_no_proxy}-2}"
        fi

        IFS=',' read -r -a no_proxy_entries <<< "$current_no_proxy"
        for entry in "${no_proxy_entries[@]}"; do
            trimmed_entry="${entry#"${entry%%[![:space:]]*}"}"
            trimmed_entry="${trimmed_entry%"${trimmed_entry##*[![:space:]]}"}"
            if [ -z "$trimmed_entry" ] || \
               [ "$trimmed_entry" = "$host_name" ] || \
               [ "$trimmed_entry" = "$short_host_name" ] || \
               [ "$trimmed_entry" = "$container_ip" ]; then
                continue
            fi
            normalized_no_proxy="${normalized_no_proxy:+${normalized_no_proxy},}${trimmed_entry}"
        done

        normalized_no_proxy="${normalized_no_proxy:+${normalized_no_proxy},}${host_name}"
        if [ "$short_host_name" != "$host_name" ]; then
            normalized_no_proxy="${normalized_no_proxy},${short_host_name}"
        fi

        if [ "$container_ip" != "$host_name" ] && \
           [ "$container_ip" != "$short_host_name" ]; then
            normalized_no_proxy="${normalized_no_proxy},${container_ip}"
        fi

        sed -i \
            -e '/^[[:space:]]*\(export[[:space:]]\+\)\?no_proxy[[:space:]]*=/d' \
            -e '/^[[:space:]]*\(export[[:space:]]\+\)\?NO_PROXY[[:space:]]*=/d' \
            "$target_file" || return 1
        if [ -s "$target_file" ] && [ -n "$(tail -c 1 "$target_file")" ]; then
            printf '\n' >> "$target_file" || return 1
        fi
        export_prefix=""
        [ "$target_file" = "$profile_file" ] && export_prefix="export "
        printf '%sno_proxy="%s"\n%sNO_PROXY="%s"\n' \
            "$export_prefix" "$normalized_no_proxy" \
            "$export_prefix" "$normalized_no_proxy" >> "$target_file" || return 1
    done
}

set_noproxy() {
    local container_ip
    local container_ip_output

    if [ -z "${hostName:-}" ] || [ -z "${shortHostName:-}" ] || \
       [ -z "${container_engine:-}" ] || [ -z "${CID:-}" ]; then
        echo "Some variables are uninitialized; skipping no_proxy setup."
        return 1
    fi

    if ! container_ip_output=$(
        "$container_engine" exec "$CID" hostname -I 2>/dev/null
    ); then
        echo "Unable to determine container IP for no_proxy setup." >&2
        return 1
    fi

    container_ip=$(printf '%s\n' "$container_ip_output" | awk '{print $1}')

    if [ -z "$container_ip" ]; then
        echo "Unable to determine container IP for no_proxy setup." >&2
        return 1
    fi

    "$container_engine" exec -i "$CID" \
        bash -s -- "$hostName" "$shortHostName" "$container_ip" <<EOF
$(declare -f normalize_noproxy_files)
normalize_noproxy_files \
    /etc/environment \
    /etc/profile.d/proxy.sh \
    "\$1" "\$2" "\$3" || exit 1
EOF
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# Linux execution requires root privileges.
if [ "$(uname -s)" = "Linux" ] && [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script requires root privileges on Linux.${NC}"
    echo "Please run it as root or with sudo."
    exit 1
fi

#checking if required memory is present or not

memory_requirement=1
if [ "$os_vers" == "Darwin" ]; then
     memory_available_mac=$(system_profiler SPHardwareDataType | grep "Memory" | awk '{print $2}')  &>/dev/null
       if  [ $memory_available_mac -lt 8 ] ; then
           echo -e "${GREEN}RAM NEEDED \t :\t 8 GB"
           echo -e "${RED}RAM AVAILABLE \t :\t $memory_available_mac GB"
           echo -e "${RED}Please try to spin up seed node on client having sufficient memory${NC}"
           memory_requirement=0
           exit
       fi
fi
if [ "$os_vers" == "Linux" ]; then
       memory_available_linux=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')  &>/dev/null
        if  [ $memory_available_linux -lt 8000000 ]; then
            echo -e "${GREEN}RAM NEEDED \t :\t 8 GB"
            echo -e "${RED}RAM AVAILABLE \t :\t $memory_available_linux"
            echo -e "${RED}Please try to spin up seed node on client having sufficient memory${NC}"
            memory_requirement=0
            exit
         fi
fi

#setting default value of container_engine to docker. Here container_engine refers to the container runtime installed.
container_engine='docker'

# Check if Docker is installed
docker info > /dev/null 2>&1
DOCKER_STATUS=$?

# Check if Podman is installed
podman info > /dev/null 2>&1
PODMAN_STATUS=$?

# If Podman is installed, set container_engine=podman
if [ $PODMAN_STATUS = 0 ]; then
    container_engine='podman'
    IMAGE="docker.io/maprtech/edf-seed-container:latest"
fi

# If docker is installed, set container_engine=docker
if [ $DOCKER_STATUS = 0 ]; then
    container_engine='docker'
fi

# If neither Docker nor Podman is available, install docker.
if [ $DOCKER_STATUS != 0 ] && [ $PODMAN_STATUS != 0 ]; then
    if [ "$os_vers" == "Darwin" ];then
    echo -e "${RED}Docker is not installed/not-running on the MacBook where this script is run. Please install/start Docker.${NC}"
    echo -e "${GREEN}Reference link to install : https://docs.docker.com/desktop/install/mac-install/${NC}"
    exit
   elif [ "$os_vers" == "Linux" ]; then
         install_docker_linux || exit 1
   fi
fi

container_engine_running=1
if ! verify_container_engine "$container_engine"; then
    container_engine_running=0
    exit 1
fi

#remove the hello-world image we ran in earlier step
CID_Hello=$($container_engine ps -a | grep hello-world | awk '{ print $1 }' | tail -1  )
if [ -n "$CID_Hello" ]; then
   $container_engine stop $CID_Hello > /dev/null 2>&1
   $container_engine rm -f $CID_Hello > /dev/null 2>&1
fi

#check if ports used by datafabric is already used by some other process
port_available=1
$container_engine ps -q > /dev/null 2>&1
if [ $? == 0 ]; then

# Define the ports you want to check
ports=(7221 5660 5692 5724 5756 8443 9443 8188 8080 7222 5181)

# Loop through each port and check if it's in use
for port in "${ports[@]}"; do

    # Check if port is in use by any container, and exclude containers with "edf-seed-container" in the image name

        if [[ "$os_vers" == "Darwin" ]]; then
            # macOS: use lsof
            port_in_use=$(lsof -nP -iTCP -sTCP:LISTEN | grep ":$port" | awk '{print $2}' | head -n 1)
        else
            # Linux: use ss
            port_in_use=$(ss -tulnp | grep ":$port " | awk '{print $6}' | cut -d',' -f2)
        fi

    if [[ -n "$port_in_use" ]]; then
        # Get the container ID using that port
        container_using_port=$($container_engine ps -q --filter "publish=$port")

        # Check if the container is excluded (based on image name containing "edf-seed-container")
        container_image=$($container_engine ps -a --filter "id=$container_using_port" --format "{{.Image}}")

        if [[ "$container_image" == *"edf-seed-container"* ]]; then
            port_available=1
        else
            echo "Please check port availability as Port $port is in use by container $container_using_port with image '$container_image'."
            port_available=0
            exit 1
        fi
    else
        port_available=1
    fi
done
fi

if [ $memory_requirement -eq 1 ]  && [ $container_engine_running -eq 1 ] && [ $port_available -eq 1 ]; then
     echo -e "\t\t${GREEN}RAM NEEDED \t :\t AVAILABLE"
     echo -e "\t\t${GREEN}$container_engine STATUS \t :\t RUNNING"
     echo -e "\t\t${GREEN}PORTS NEEDED \t :\t AVAILABLE"
     echo -e "\t\tPROCEEDING FORWARD WITH DEPLOYING SEED NODE${NC}"
fi


while [ $# -gt 0 ]
do
  case "$1" in
  -i|--image) shift;
  IMAGE=$1;;
  -p|--publicipv4dns) shift;
  PUBLICIPV4DNS=$1;;
  -f|--proxyfiledetails) shift;
  if [ $# -eq 0 ] || [ ! -r "$1" ]; then
      echo "Proxy details file is missing or unreadable: ${1:-<missing>}" >&2
      exit 1
  fi
  PROXYFILEDETAILS=$1;;
  -r|--repo_url) shift;
  REPO_URL=$1;;
  -l|--local)
  LOCAL_IMAGE=true;;
  --legacy-docker-install)
  legacy_docker_install=true;;
  *) shift;
   usage
   exit;;
   esac
   shift
done

which ipconfig &>/dev/null
if [ $? -eq 0 ]; then
  INTERFACE=$(route -n get default | grep interface | awk '{print $2}')
  IP=$(ipconfig getifaddr $INTERFACE)
else
  INTERFACE=$(ip route | grep default | awk '{print $5}')
  IP=$(ip addr show "$INTERFACE" | grep -w inet | awk '{ print $2}' | cut -d "/" -f1 | head -1)
fi
hostName="${hostName:-"edf-installer.hpe.com"}"
clusterName=$(echo ${hostName} | cut -d '.' -f 1)
shortHostName=$(echo $hostName | awk -F '.' '{print $1}')

# Seed image is amd64-only; Apple Silicon Macs must emulate it.
PLATFORM_OPT=""
if [ "$(uname -s)" == "Darwin" ] && [ "$(uname -m)" == "arm64" ]; then
    PLATFORM_OPT="--platform linux/amd64"
fi


runMaprImage() {
    echo "Please enter the local sudo password for $(whoami)"
        sudo rm -rf /tmp/maprdemo
        sudo mkdir -p /tmp/maprdemo/hive /tmp/maprdemo/zkdata /tmp/maprdemo/pid /tmp/maprdemo/logs /tmp/maprdemo/nfs
        sudo chmod -R 777 /tmp/maprdemo/hive /tmp/maprdemo/zkdata /tmp/maprdemo/pid /tmp/maprdemo/logs /tmp/maprdemo/nfs

        PORTS=' -p 2222:22 -p 7221:7221  -p 5660:5660 -p 8443:8443  -p 8080:8080  -p 8188:8188  -p 7222:7222 -p 5181:5181  -p 5692:5692 -p 5724:5724 -p 5756:5756 -p 9443:9443'
        #export MAPR_EXTERNAL="0.0.0.0"
  #incase non-mac ipconfig command would not be found
  which ipconfig &>/dev/null
  if [ $? -eq 0 ]; then
    export MAPR_EXTERNAL=$(ipconfig getifaddr $INTERFACE)
  else
    export MAPR_EXTERNAL=$(ip addr show "$INTERFACE" | grep -w inet | awk '{ print $2}' | cut -d "/" -f1 | head -1)
  fi


  if [ "${PUBLICIPV4DNS}" == "" ]; then
        echo ""
  else
    export PUBLICIPV4DNS="${PUBLICIPV4DNS}"
  fi

        if [ "${LOCAL_IMAGE}" == "true" ]; then
             echo "Using local image: ${IMAGE}, skipping pull."
        else
             $container_engine pull ${PLATFORM_OPT} ${IMAGE}
             if [ $? != 0 ]; then
                  echo "Failed to pull the image"
                  exit 1
             fi
        fi
        $container_engine ps -a | grep edf-seed-container > /dev/null 2>&1
        if [ $? == 0 ]; then

              running_CID=$($container_engine ps -a | grep edf-seed-container | awk '{ print $1 }' )
              $container_engine stop $running_CID > /dev/null 2>&1
              $container_engine rm $running_CID > /dev/null 2>&1
              sleep 3
        else
              $container_engine stop $container_using_port > /dev/null 2>&1
              $container_engine rm $container_using_port > /dev/null 2>&1
              sleep 3
        fi
        isSecure="${isSecure:-false}"
        REPO_URL="${REPO_URL:-}"

        $container_engine run -d --privileged \
          $PLATFORM_OPT \
          -v /tmp/maprdemo/zkdata:/opt/mapr/zkdata \
          -v /tmp/maprdemo/pid:/opt/mapr/pid \
          -v /tmp/maprdemo/logs:/opt/mapr/logs \
          -v /tmp/maprdemo/nfs:/mapr \
          $PORTS \
          -e "MAPR_EXTERNAL=${MAPR_EXTERNAL}" \
          -e "clusterName=${clusterName}" \
          -e "isSecure=${isSecure}" \
          -e "REPO_URL=${REPO_URL}" \
          --hostname "${clusterName}" \
          "${IMAGE}" > /dev/null 2>&1
   # Check if container is started wihtout any issue
   sleep 5 # wait for container to start

    CID=$($container_engine ps -a | grep edf-seed-container | awk '{ print $1 }' )
    RUNNING=$($container_engine inspect --format="{{.State.Running}}" $CID 2> /dev/null)
    ERROR=$($container_engine inspect --format="{{.State.Error}}" $CID 2> /dev/null)

    if [ "$RUNNING" == "true" -a "$ERROR" == "" ]
    then
            echo "Developer Sandbox Container $CID is running..."
    else
            echo "Failed to start Developer Sandbox Container $CID. Error: $ERROR"
            exit
    fi
}

    if [ "$RUNNING" == "true" ]
        then
                # Container is running.
                # Change the IP in /etc/hosts and reconfigure client for the IP Change
                # Change the server side settings and restart warden
                grep ${hostName} /etc/hosts | grep ${IP} > /dev/null 2>&1
                if [ $? -ne 0 ]
                then
                        echo "Please enter the local sudo password for $(whoami)"
                        sudo sed -i  '/'${hostName}'/d' /etc/hosts &>/dev/null
                        sudo  sh -c "echo  \"${IP}      ${hostName}  ${clusterName}\" >> /etc/hosts"
                        sudo sed -i '' '/'${hostName}'/d' /opt/mapr/conf/mapr-clusters.conf &>/dev/null
                        sudo /opt/mapr/server/configure.sh -C ${hostName}  -N ${clusterName} > /dev/null 2>&1
                        # Change the external IP in the container
                        echo "Please enter the root password of the container 'mapr' "
                        ssh root@localhost -p 2222 " sed -i \"s/MAPR_EXTERNAL=.*/MAPR_EXTERNAL=${IP}/\" /opt/mapr/conf/env.sh "
                        echo "Please enter the root password of the container 'mapr' "
                        ssh root@localhost -p 2222 "service mapr-warden restart"
                fi
        fi

        runMaprImage

        if [ "$os_vers" != "Darwin" ]; then
            sudo sed -i  '/'${hostName}'/d' /etc/hosts &>/dev/null
        fi

        os_vers=`uname -s` > /dev/null 2>&1

        rm -f /tmp/proxyseednode.base || exit 1

        "$container_engine" cp "${CID}:/etc/environment" /tmp/proxyseednode.base || exit 1

        : > /tmp/proxyseednode || exit 1
        append_environment_file /tmp/proxyseednode.base /tmp/proxyseednode || exit 1
        printf '%s\n' 'SEED_NODE=true' >> /tmp/proxyseednode || exit 1

        explicit_proxy_profile=""
        if [ "$os_vers" = "Darwin" ] || [ "$os_vers" = "Linux" ]; then
            if [ -n "${PROXYFILEDETAILS:-}" ]; then
                explicit_proxy_profile=$(mktemp "${TMPDIR:-/tmp}/datafabric-explicit-proxy.XXXXXX") || exit 1
                if ! append_proxy_environment_file "$PROXYFILEDETAILS" /tmp/proxyseednode "$explicit_proxy_profile"; then
                    rm -f "$explicit_proxy_profile"
                    exit 1
                fi
            elif [ "$os_vers" = "Linux" ]; then
                append_proxy_environment_file /etc/environment /tmp/proxyseednode || exit 1
            fi
        fi

        if ! "$container_engine" cp /tmp/proxyseednode "${CID}:/etc/environment" > /dev/null 2>&1; then
            rm -f /tmp/proxyseednode /tmp/proxyseednode.base "${explicit_proxy_profile:-}"
            exit 1
        fi

        rm -f /tmp/proxyseednode /tmp/proxyseednode.base

        if [ -n "${explicit_proxy_profile:-}" ]; then
            if ! merge_proxy_profile "$explicit_proxy_profile"; then
                rm -f "$explicit_proxy_profile"
                exit 1
            fi
            rm -f "$explicit_proxy_profile"
        elif [ "$os_vers" = "Linux" ] && [ -z "${PROXYFILEDETAILS:-}" ]; then
            merge_proxy_profile /etc/profile.d/proxy.sh || exit 1
        fi

        set_noproxy || exit 1
        services_up=0
        sleep_total=900
        sleep_counter=0
        if [ "$os_vers" == "Darwin" ]; then
           while [[ $sleep_counter -le $sleep_total ]]
            do
             # --resolve avoids needing an /etc/hosts entry (sudo edits may be blocked on managed Macs).
             curl -k --resolve "${hostName}:8443:127.0.0.1" -X GET "https://${hostName}:8443/rest/node/list?columns=svc" -u mapr:mapr123 &>/dev/null
             if [ $? -ne 0 ];then
                echo "Services required for HPE Data Fabric are coming up"
                sleep 60;
                sleep_counter=$((sleep_counter+60))
             else
                services_up=1
                break
             fi
           done
       fi
       if [ "$os_vers" == "Linux" ]; then
           while [[ $sleep_counter -le $sleep_total ]]
            do
             curl -k -X GET https://`hostname -f`:8443/rest/node/list?columns=svc -u mapr:mapr123 &>/dev/null
             if [ $? -ne 0 ];then
                echo "Services required for HPE Data Fabric are coming up"
                sleep 60;
                sleep_counter=$((sleep_counter+60))
             else
                services_up=1
                break
             fi
           done
       fi


       if [ $services_up -eq 1 ]; then
           echo
           echo "Client has been configured with the $container_engine container."
           echo
           if [   "${PUBLICIPV4DNS}" == "" ]; then
                echo "Please click on the link https://"${MAPR_EXTERNAL}":8443/app/df-installer/ to deploy Data Fabric"
                echo "For user documentation, see https://docs.ezmeral.hpe.com/datafabric/home/installation/installation_main.html"
                echo
           else
                echo "Please click on the link  https://"${PUBLICIPV4DNS}":8443/app/df-installer/  to deploy Data Fabric"
                echo "For user documentation, see https://docs.ezmeral.hpe.com/datafabric/home/installation/installation_main.html"

          fi
       else
          echo
          echo "Services didn't come up in the stipulated 10 mins time."
          echo "Please log in to the container using ssh root@localhost -p 2222 with mapr as the password and check further"
          echo "For documentation on steps to debug, see https://docs.ezmeral.hpe.com/datafabric/home/installation/troubleshooting_seed_node_installation.html"
          echo "Once all services are up, the Data Fabric UI is available at https://"${MAPR_EXTERNAL}":8443/app/df-installer/  and Data Fabric can be deployed from that page"
          echo
       fi
