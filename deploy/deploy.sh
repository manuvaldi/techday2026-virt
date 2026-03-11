#!/bin/bash

DEFAULT_RELEASE="platform-vms"
CHART_DIR="./charts/stock-app"
CURRENT_USERS=""

SHOWROOM_CHART_DIR="./charts/showroom-single-pod"
SHOWROOM_REPO="https://github.com/rhpds/showroom-deployer.git"
SHOWROOM_VALUES="values.yaml"

mkdir -p ./kubeconfigs

ensure_connected() {
    if ! oc whoami >/dev/null 2>&1; then
        echo "Error: Not connected to any cluster. Please use Option 9 to connect first."
        return 1
    fi
    return 0
}

cluster_management_menu() {
    while true; do
        echo "=========================================="
        echo "           CLUSTER MANAGEMENT             "
        echo "=========================================="
        echo "1. Switch to an existing Kubeconfig"
        echo "2. Add new cluster (Paste full 'oc login' command)"
        echo "3. Add new cluster (Enter URL and Token)"
        echo "4. Return to Main Menu"
        read -p "Select an option [1-4]: " cm_choice

        case $cm_choice in
            1)
                local configs=(./kubeconfigs/*.kubeconfig)
                if [ ! -e "${configs[0]}" ]; then
                    echo "Error: No saved kubeconfigs found in ./kubeconfigs/"
                    continue
                fi
                echo -e "\nAvailable configurations:"
                for i in "${!configs[@]}"; do
                    echo "$((i+1)). $(basename "${configs[$i]}")"
                done
                read -p "Select a number to switch (or Enter to cancel): " conf_idx
                if [[ "$conf_idx" =~ ^[0-9]+$ ]] && [ "$conf_idx" -gt 0 ] && [ "$conf_idx" -le "${#configs[@]}" ]; then
                    export KUBECONFIG="$(pwd)/${configs[$((conf_idx-1))]}"
                    if oc whoami >/dev/null 2>&1; then
                        echo "Successfully switched KUBECONFIG to: $(basename "$KUBECONFIG")"
                        break
                    else
                        echo "Warning: Switched to $(basename "$KUBECONFIG"), but the token seems expired or invalid."
                        break
                    fi
                elif [ -n "$conf_idx" ]; then
                    echo "Invalid selection."
                fi
                ;;
            2)
                read -p "Enter a reference name for this cluster (e.g. azure): " k_name
                if [ -z "$k_name" ]; then echo "Error: Name cannot be empty."; continue; fi
                
                read -p "Paste the full 'oc login ...' command: " oc_cmd
                if [[ ! "$oc_cmd" =~ ^oc[[:space:]]+login ]]; then
                    echo "Error: Invalid command. It must start with 'oc login'"
                    continue
                fi
                
                export KUBECONFIG="$(pwd)/kubeconfigs/${k_name}.kubeconfig"
                echo "Attempting login..."
                eval "$oc_cmd --insecure-skip-tls-verify=true" >/dev/null 2>&1
                
                if [ $? -eq 0 ]; then
                    echo "Successfully logged in and saved to kubeconfigs/${k_name}.kubeconfig"
                    break
                else
                    echo "Error: Login failed. Please check your command."
                    unset KUBECONFIG
                fi
                ;;
            3)
                read -p "Enter a reference name for this cluster (e.g. baremetal): " k_name
                if [ -z "$k_name" ]; then echo "Error: Name cannot be empty."; continue; fi
                
                read -p "Server URL (e.g. https://api...): " cluster_server
                if [ -z "$cluster_server" ]; then echo "Error: URL cannot be empty."; continue; fi
                
                read -s -p "Login token: " cluster_token
                echo ""
                if [ -z "$cluster_token" ]; then echo "Error: Token cannot be empty."; continue; fi

                export KUBECONFIG="$(pwd)/kubeconfigs/${k_name}.kubeconfig"
                echo "Attempting login..."
                oc login --token="$cluster_token" --server="$cluster_server" --insecure-skip-tls-verify=true >/dev/null 2>&1
                
                if [ $? -eq 0 ]; then
                    echo "Successfully logged in and saved to kubeconfigs/${k_name}.kubeconfig"
                    break
                else
                    echo "Error: Login failed. Check the token and URL."
                    unset KUBECONFIG
                fi
                ;;
            4) break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

show_menu() {
    local current_server=$(oc whoami --show-server 2>/dev/null)
    local current_user=$(oc whoami 2>/dev/null)
    local status_text="NOT CONNECTED"
    
    if [ -n "$current_server" ] && [ -n "$current_user" ]; then
        status_text="$current_user @ $current_server"
    fi

    echo "=========================================="
    echo "             DEPLOYMENT MENU              "
    echo "=========================================="
    echo " TARGET: $status_text"
    echo "=========================================="
    echo "--- Standard Infrastructure (VMs) ---"
    echo "1. Deploy with default users"
    echo "2. Deploy with custom users"
    echo -e "\n--- App Only Infrastructure (NO VMs) ---"
    echo "3. Deploy WITHOUT VMs (Default users)"
    echo "4. Deploy WITHOUT VMs (Custom users)"
    echo -e "\n--- Teardown ---"
    echo "5. Uninstall release"
    echo "6. Uninstall release AND clean namespaces"
    echo -e "\n--- Lab Environment ---"
    echo "7. Deploy Showroom"
    echo "8. Uninstall Showroom"
    echo -e "\n--- Cluster Management ---"
    echo "9. Switch / Generate Kubeconfig"
    echo "=========================================="
    echo "10. Exit"
    echo "=========================================="
}

read_release_name() {
    read -p "Enter release name [$DEFAULT_RELEASE]: " input_release
    RELEASE_NAME=${input_release:-$DEFAULT_RELEASE}
}

ask_acm_policy() {
    read -p "Enable User Defined Network (UDN) policies for this deployment? (y/n): " acm_choice
    if [[ "$acm_choice" == "y" ]]; then
        ACM_FLAG="--set enableUDN=true"
        echo "UDN policies enabled."
    else
        ACM_FLAG=""
        echo "UDN policies disabled."
    fi
}

get_default_users_only() {
    CURRENT_USERS=$(grep -E '^[[:space:]]*users:' "$CHART_DIR/values.yaml" 2>/dev/null | cut -d ':' -f2 | tr -d ' []{}"'\''' | tr -d ' ')
    if [ -z "$CURRENT_USERS" ]; then
        CURRENT_USERS=$(awk '/^[[:space:]]*users:/{flag=1; next} /^[[:space:]]*[a-zA-Z0-9_]+:/{flag=0} flag && /^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/["'\''\r]/,""); print}' "$CHART_DIR/values.yaml" 2>/dev/null | paste -sd, -)
    fi

    if [ -z "$CURRENT_USERS" ]; then
        echo "Error: Could not extract default users from $CHART_DIR/values.yaml"
        return 1
    fi
    return 0
}

get_users() {
    local extracted_users=""
    grep -E '^[[:space:]]*users:' "$CHART_DIR/values.yaml" 2>/dev/null | cut -d ':' -f2 | tr -d ' []{}"'\''' | tr -d ' ' > /tmp/ext_users.txt
    extracted_users=$(cat /tmp/ext_users.txt)
    
    if [ -z "$extracted_users" ]; then
        awk '/^[[:space:]]*users:/{flag=1; next} /^[[:space:]]*[a-zA-Z0-9_]+:/{flag=0} flag && /^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/["'\''\r]/,""); print}' "$CHART_DIR/values.yaml" 2>/dev/null | paste -sd, - > /tmp/ext_users.txt
        extracted_users=$(cat /tmp/ext_users.txt)
    fi
    rm -f /tmp/ext_users.txt
    
    local prompt_msg="Enter number of users (e.g. 5) OR a comma-separated list"
    
    if [ -n "$CURRENT_USERS" ]; then
        prompt_msg="Enter number or list (Press Enter to keep: $CURRENT_USERS)"
    elif [ -n "$extracted_users" ]; then
        prompt_msg="Enter number or list (Press Enter for defaults from values: $extracted_users)"
    fi

    read -p "$prompt_msg: " input_users
    
    if [ -n "$input_users" ]; then
        if [[ "$input_users" =~ ^[0-9]+$ ]] && [ "$input_users" -gt 0 ]; then
            CURRENT_USERS=""
            for i in $(seq 1 $input_users); do
                CURRENT_USERS+="user${i},"
            done
            CURRENT_USERS=${CURRENT_USERS%,}
            echo "Generated N users dynamically: $CURRENT_USERS"
        else
            CURRENT_USERS="$input_users"
        fi
    elif [ -z "$CURRENT_USERS" ] && [ -n "$extracted_users" ]; then
        CURRENT_USERS="$extracted_users"
    fi
    
    if [ -z "$CURRENT_USERS" ]; then
        echo "Error: No users provided."
        return 1
    fi
    
    return 0
}

generate_and_apply_passwords() {
    local skip_generation="false"

    if [ -f "users.htpasswd" ] && [ -f "lab_credentials.txt" ]; then
        echo ""
        read -p "Existing credentials found. Reuse them for this cluster? (y/n): " reuse_creds
        if [[ "$reuse_creds" == "y" ]]; then
            CURRENT_USERS=$(awk -F':' '{print $1}' users.htpasswd | paste -sd, -)
            echo "Reusing existing credentials for users: $CURRENT_USERS"
            skip_generation="true"
        fi
    fi

    if [ "$skip_generation" == "false" ]; then
        echo -e "\nGenerating passwords for users"
        echo "1. Different random password per user (Default)"
        echo "2. Same random password for all users"
        echo "3. Custom password for all users"
        read -p "Select a password strategy [1-3]: " pass_choice
        pass_choice=${pass_choice:-1}
        
        local common_pass=""
        if [ "$pass_choice" == "2" ]; then
            common_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
            echo "Generated common password: $common_pass"
        elif [ "$pass_choice" == "3" ]; then
            read -s -p "Enter the custom password to use for all users: " common_pass
            echo ""
            if [ -z "$common_pass" ]; then
                common_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
                pass_choice="2"
            fi
        fi

        > lab_credentials.txt
        > users.htpasswd

        local IFS=','
        for user in $CURRENT_USERS; do
            local current_pass=""
            if [ "$pass_choice" == "1" ]; then
                current_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
            else
                current_pass="$common_pass"
            fi
            
            echo "User: $user  |  Password: $current_pass" | tee -a lab_credentials.txt
            htpasswd -b -B users.htpasswd "$user" "$current_pass" >/dev/null 2>&1
        done
    fi

    oc create secret generic htpasswd-users-secret --from-file=htpasswd=users.htpasswd -n openshift-config --dry-run=client -o yaml | oc apply -f -

    local idp_name="lab-users-htpasswd"
    if ! oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null | grep -q "$idp_name"; then
        echo "Configuring OAuth Identity Provider in cluster..."
        
        oc patch oauth cluster --type=json -p='[{"op": "add", "path": "/spec/identityProviders/-", "value": {"name": "'$idp_name'", "mappingMethod": "claim", "type": "HTPasswd", "htpasswd": {"fileData": {"name": "htpasswd-users-secret"}}}}]' >/dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            oc patch oauth cluster --type=merge -p='{"spec": {"identityProviders": [{"name": "'$idp_name'", "mappingMethod": "claim", "type": "HTPasswd", "htpasswd": {"fileData": {"name": "htpasswd-users-secret"}}}]}}' >/dev/null 2>&1
        fi
        
        echo "Identity Provider created. OAuth pods will restart."
    fi
}

deploy_default() {
    ensure_connected || return
    read_release_name
    get_default_users_only || return
    ask_acm_policy
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" $ACM_FLAG
}

deploy_custom() {
    ensure_connected || return
    read_release_name
    get_users || return
    ask_acm_policy
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set "rbac.users={$CURRENT_USERS}" $ACM_FLAG
}

deploy_no_vms_default() {
    ensure_connected || return
    read_release_name
    get_default_users_only || return
    ask_acm_policy
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set vms.enabled=false $ACM_FLAG
}

deploy_no_vms_custom() {
    ensure_connected || return
    read_release_name
    get_users || return
    ask_acm_policy
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set "rbac.users={$CURRENT_USERS}" --set vms.enabled=false $ACM_FLAG
}

uninstall_release() {
    ensure_connected || return
    read_release_name
    helm uninstall "$RELEASE_NAME"
}

uninstall_and_clean() {
    ensure_connected || return
    read_release_name
    get_users || return
    
    helm uninstall "$RELEASE_NAME"

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        kubectl delete namespace "${user}-application" --ignore-not-found
    done
}

inject_oauth_proxy() {
    local user=$1
    local namespace="${user}-application"
    local app_name="showroom-${user}"
    
    if [ ! -f "oauth-sidecar.yaml" ]; then
        return 1
    fi

    local oauth_image=$(oc adm release info --image-for=oauth-proxy)
    local cookie_secret=$(openssl rand -base64 32 | head -c 32)

    local sa_name=$(oc get deployment $app_name -n $namespace -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
    if [ -z "$sa_name" ]; then
        sa_name="default"
    fi

    sed -e "s|{{COOKIE_SECRET}}|${cookie_secret}|g" \
        -e "s|{{OAUTH_PROXY_IMAGE}}|${oauth_image}|g" \
        -e "s|{{SERVICE_ACCOUNT}}|${sa_name}|g" \
        oauth-sidecar.yaml > /tmp/patch-${app_name}.yaml

    oc patch deployment $app_name -n $namespace --patch-file /tmp/patch-${app_name}.yaml >/dev/null 2>&1
    rm -f /tmp/patch-${app_name}.yaml

    oc patch service $app_name -n $namespace --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8888}]' >/dev/null 2>&1
    oc patch route $app_name -n $namespace -p '{"spec":{"port":{"targetPort":8888},"tls":{"termination":"edge"}}}' >/dev/null 2>&1

    oc annotate serviceaccount $sa_name serviceaccounts.openshift.io/oauth-redirectreference.primary='{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"'${app_name}'"}}' -n $namespace --overwrite >/dev/null 2>&1
}

deploy_showroom() {
    ensure_connected || return
    get_users || return

    if [ ! -f "users.htpasswd" ]; then
        generate_and_apply_passwords
    fi

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        if ! kubectl get namespace "${user}-application" >/dev/null 2>&1; then
            kubectl create namespace "${user}-application" >/dev/null 2>&1
        fi
    done

    if [ ! -d "$SHOWROOM_CHART_DIR" ]; then
        mkdir -p ./charts
        git clone --depth 1 $SHOWROOM_REPO /tmp/showroom-deployer >/dev/null 2>&1
        cp -r /tmp/showroom-deployer/charts/showroom-single-pod ./charts/
        rm -rf /tmp/showroom-deployer
    fi

    if [ ! -f "$SHOWROOM_VALUES" ]; then
        return
    fi

    local console_url=$(oc whoami --show-console)
    local ui_config_file="../uiConfig"

    for user in "${USER_ARRAY[@]}"; do
        if [ -f "$ui_config_file" ]; then
            sed "s|{{CONSOLE_URL}}|${console_url}|g" "$ui_config_file" > "/tmp/ui-${user}.yaml"
            helm upgrade --install "showroom-${user}" "$SHOWROOM_CHART_DIR" -f "$SHOWROOM_VALUES" --namespace "${user}-application" --set "guid=${user}" --set-file "content.uiConfig=/tmp/ui-${user}.yaml"
        else
            helm upgrade --install "showroom-${user}" "$SHOWROOM_CHART_DIR" -f "$SHOWROOM_VALUES" --namespace "${user}-application" --set "guid=${user}"
        fi

        rm -f "/tmp/ui-${user}.yaml"
        inject_oauth_proxy "$user"
        oc adm policy add-role-to-user edit $user -n "${user}-application" >/dev/null 2>&1
    done
}

uninstall_showroom() {
    ensure_connected || return
    get_users || return

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        helm uninstall showroom-${user} --namespace "${user}-application" --ignore-not-found
        
        if ! helm status $RELEASE_NAME >/dev/null 2>&1; then
            kubectl delete namespace "${user}-application" --ignore-not-found
        fi
    done
}

if ! oc whoami >/dev/null 2>&1; then
    echo "Welcome! No active cluster connection detected. Let's set one up."
    cluster_management_menu
fi

while true; do
    show_menu
    read -p "Select an option [1-10]: " choice
    echo ""
    case $choice in
        1) deploy_default ;;
        2) deploy_custom ;;
        3) deploy_no_vms_default ;;
        4) deploy_no_vms_custom ;;
        5) uninstall_release ;;
        6) uninstall_and_clean ;;
        7) deploy_showroom ;;
        8) uninstall_showroom ;;
        9) cluster_management_menu ;;
        10) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo ""
done
