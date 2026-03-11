#!/bin/bash

DEFAULT_RELEASE="platform-vms"
CHART_DIR="./charts/stock-app"
CURRENT_USERS=""

SHOWROOM_CHART_DIR="./charts/showroom-single-pod"
SHOWROOM_REPO="https://github.com/rhpds/showroom-deployer.git"
SHOWROOM_VALUES="values.yaml"

generate_custom_kubeconfig() {
    echo "--- Configure new Cluster connection ---"
    read -p "Server URL (e.g. https://api...): " cluster_server
    read -s -p "Login token: " cluster_token
    echo ""
    read -p "Kubeconfig file name (e.g. azure.kubeconfig) or Enter for default: " kubeconfig_file
    
    if [ -n "$kubeconfig_file" ]; then
        export KUBECONFIG="$(pwd)/$kubeconfig_file"
        echo "Temporary KUBECONFIG configured at: $KUBECONFIG"
    fi
    
    oc login --token="$cluster_token" --server="$cluster_server" --insecure-skip-tls-verify=true
    
    if [ $? -ne 0 ]; then
        echo "Error: Login failed. Check the token and URL."
        exit 1
    fi
}

check_cluster_connection() {
    if ! oc whoami >/dev/null 2>&1; then
        echo "No active cluster connection detected."
        generate_custom_kubeconfig
    fi

    local current_context=$(oc config current-context 2>/dev/null)
    local current_server=$(oc whoami --show-server 2>/dev/null)
    local current_user=$(oc whoami 2>/dev/null)

    echo "=========================================="
    echo "            CLUSTER VALIDATION            "
    echo "=========================================="
    echo "Context: $current_context"
    echo "Server:  $current_server"
    echo "User:    $current_user"
    echo "=========================================="
    
    read -p "Proceed with deployment on this cluster? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Execution aborted."
        exit 0
    fi
}

show_menu() {
    echo "=========================================="
    echo "             DEPLOYMENT MENU              "
    echo "=========================================="
    echo "--- Standard Infrastructure (VMs) ---"
    echo "1. Deploy with default users"
    echo "2. Deploy with custom users"
    echo -e "\n--- App Only Infrastructure (NO VMs) ---"
    echo "3. Deploy WITHOUT VMs (Default users)"
    echo "4. Deploy WITHOUT VMs (Custom users)"
    echo -e "\n--- Azure Infrastructure (ACM) ---"
    echo "5. Deploy for Azure (Default users)"
    echo "6. Deploy for Azure (Custom users)"
    echo -e "\n--- Teardown ---"
    echo "7. Uninstall release"
    echo "8. Uninstall release AND clean namespaces"
    echo -e "\n--- Lab Environment ---"
    echo "9. Deploy Showroom"
    echo "10. Uninstall Showroom"
    echo -e "\n--- Cluster Management ---"
    echo "11. Switch / Generate Kubeconfig"
    echo "=========================================="
    echo "12. Exit"
    echo "=========================================="
}

read_release_name() {
    read -p "Enter release name [$DEFAULT_RELEASE]: " input_release
    RELEASE_NAME=${input_release:-$DEFAULT_RELEASE}
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
    read_release_name
    get_default_users_only || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR"
}

deploy_custom() {
    read_release_name
    get_users || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set "rbac.users={$CURRENT_USERS}"
}

deploy_no_vms_default() {
    read_release_name
    get_default_users_only || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set vms.enabled=false
}

deploy_no_vms_custom() {
    read_release_name
    get_users || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set "rbac.users={$CURRENT_USERS}" --set vms.enabled=false
}

deploy_azure_default() {
    read_release_name
    get_default_users_only || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set isAzure=true
}

deploy_azure_custom() {
    read_release_name
    get_users || return
    generate_and_apply_passwords
    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --set "rbac.users={$CURRENT_USERS}" --set isAzure=true
}

uninstall_release() {
    read_release_name
    helm uninstall "$RELEASE_NAME"
}

uninstall_and_clean() {
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
    get_users || return

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        helm uninstall showroom-${user} --namespace "${user}-application" --ignore-not-found
        
        if ! helm status $RELEASE_NAME >/dev/null 2>&1; then
            kubectl delete namespace "${user}-application" --ignore-not-found
        fi
    done
}

check_cluster_connection

while true; do
    show_menu
    read -p "Select an option [1-12]: " choice
    echo ""
    case $choice in
        1) deploy_default ;;
        2) deploy_custom ;;
        3) deploy_no_vms_default ;;
        4) deploy_no_vms_custom ;;
        5) deploy_azure_default ;;
        6) deploy_azure_custom ;;
        7) uninstall_release ;;
        8) uninstall_and_clean ;;
        9) deploy_showroom ;;
        10) uninstall_showroom ;;
        11) generate_custom_kubeconfig ;;
        12) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo ""
done
