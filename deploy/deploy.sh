#!/bin/bash

DEFAULT_RELEASE="platform-vms"
CHART_DIR="./charts/stock-app"
CURRENT_USERS=""

SHOWROOM_CHART_DIR="./charts/showroom-single-pod"
SHOWROOM_REPO="https://github.com/rhpds/showroom-deployer.git"
SHOWROOM_VALUES="values.yaml"

show_menu() {
    echo "=========================================="
    echo "             DEPLOYMENT MENU              "
    echo "=========================================="
    echo "--- Infrastructure (VMs) ---"
    echo "1. Deploy with default users (values.yaml)"
    echo "2. Deploy with custom users"
    echo "3. Uninstall release"
    echo "4. Uninstall release AND clean namespaces"
    echo "--- Lab Environment (Showroom) ---"
    echo "5. Deploy Showroom (Docs & Terminal)"
    echo "6. Uninstall Showroom"
    echo "=========================================="
    echo "7. Exit"
    echo "=========================================="
}

read_release_name() {
    read -p "Enter release name [$DEFAULT_RELEASE]: " input_release
    RELEASE_NAME=${input_release:-$DEFAULT_RELEASE}
}

get_users() {
    local extracted_users=$(grep -E '^[[:space:]]*users:' "$CHART_DIR/values.yaml" 2>/dev/null | cut -d ':' -f2 | tr -d ' []{}"'\''' | tr -d ' ')
    
    if [ -z "$extracted_users" ]; then
        extracted_users=$(awk '/^[[:space:]]*users:/{flag=1; next} /^[[:space:]]*[a-zA-Z0-9_]+:/{flag=0} flag && /^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/["'\''\r]/,""); print}' "$CHART_DIR/values.yaml" 2>/dev/null | paste -sd, -)
    fi
    
    local prompt_msg="Enter comma-separated list of users (e.g. user1,user2)"
    
    if [ -n "$CURRENT_USERS" ]; then
        prompt_msg="Enter comma-separated list of users (Press Enter to keep: $CURRENT_USERS)"
    elif [ -n "$extracted_users" ]; then
        prompt_msg="Enter comma-separated list of users (Press Enter for defaults from values.yaml: $extracted_users)"
    fi

    read -p "$prompt_msg: " input_users
    
    if [ -n "$input_users" ]; then
        CURRENT_USERS="$input_users"
    elif [ -z "$CURRENT_USERS" ] && [ -n "$extracted_users" ]; then
        CURRENT_USERS="$extracted_users"
    fi
    
    if [ -z "$CURRENT_USERS" ]; then
        echo "Error: No users provided."
        return 1
    fi
    return 0
}

deploy_default() {
    read_release_name
    echo "Deploying infrastructure with default users..."
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_DIR"
    echo "Executing: $HELM_CMD"
    eval $HELM_CMD
}

deploy_custom() {
    read_release_name
    get_users || return
    
    echo "Deploying infrastructure for users: $CURRENT_USERS"
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_DIR --set rbac.users={$CURRENT_USERS}"
    echo "Executing: $HELM_CMD"
    eval $HELM_CMD
}

uninstall_release() {
    read_release_name
    echo "Uninstalling release: $RELEASE_NAME"
    helm uninstall $RELEASE_NAME
}

uninstall_and_clean() {
    read_release_name
    get_users || return
    
    echo "Uninstalling release: $RELEASE_NAME"
    helm uninstall $RELEASE_NAME

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        echo "Force deleting namespace: ${user}-application"
        kubectl delete namespace "${user}-application" --ignore-not-found
    done
}

deploy_showroom() {
    echo "--- Deploying Showroom for multiple users ---"
    
    if [ ! -d "$SHOWROOM_CHART_DIR" ]; then
        echo "Showroom chart not found. Downloading from RHPDS..."
        mkdir -p ./charts
        git clone --depth 1 $SHOWROOM_REPO /tmp/showroom-deployer
        cp -r /tmp/showroom-deployer/charts/showroom-single-pod ./charts/
        rm -rf /tmp/showroom-deployer
        echo "Chart successfully downloaded to $SHOWROOM_CHART_DIR"
    fi

    if [ ! -f "$SHOWROOM_VALUES" ]; then
        echo "Error: The file $SHOWROOM_VALUES does not exist in this directory."
        echo "Please create it first with your Antora repository configuration."
        return
    fi

    get_users || return

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        echo "----------------------------------------"
        echo "Deploying Showroom for: $user"
        echo "Namespace: ${user}-application"
        HELM_CMD="helm upgrade --install showroom-${user} $SHOWROOM_CHART_DIR -f $SHOWROOM_VALUES --namespace ${user}-application --create-namespace --set guid=${user}"
        echo "Executing: $HELM_CMD"
        eval $HELM_CMD
    done
}

uninstall_showroom() {
    echo "--- Uninstalling Showroom ---"
    get_users || return

    IFS=',' read -ra USER_ARRAY <<< "$CURRENT_USERS"
    for user in "${USER_ARRAY[@]}"; do
        echo "Uninstalling Showroom for user: $user from namespace: ${user}-application"
        helm uninstall showroom-${user} --namespace "${user}-application" --ignore-not-found
    done
}

while true; do
    show_menu
    read -p "Select an option [1-7]: " choice
    echo ""
    case $choice in
        1) deploy_default ;;
        2) deploy_custom ;;
        3) uninstall_release ;;
        4) uninstall_and_clean ;;
        5) deploy_showroom ;;
        6) uninstall_showroom ;;
        7) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
    echo ""
done
