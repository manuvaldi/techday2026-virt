#!/bin/bash

DEFAULT_RELEASE="platform-vms"
CHART_DIR="./charts/stock-app"

show_menu() {
    echo "=========================================="
    echo "             DEPLOYMENT MENU              "
    echo "=========================================="
    echo "1. Deploy with default users (values.yaml)"
    echo "2. Deploy with custom users"
    echo "3. Uninstall release"
    echo "4. Uninstall release AND clean namespaces"
    echo "5. Exit"
    echo "=========================================="
}

read_release_name() {
    read -p "Enter release name [$DEFAULT_RELEASE]: " input_release
    RELEASE_NAME=${input_release:-$DEFAULT_RELEASE}
}

deploy_default() {
    read_release_name
    echo "Deploying with default users..."
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_DIR"
    echo "Executing: $HELM_CMD"
    eval $HELM_CMD
}

deploy_custom() {
    read_release_name
    read -p "Enter comma-separated list of users (e.g. user1,user2): " USERS
    if [ -z "$USERS" ]; then
        echo "Error: No users provided. Returning to menu."
        return
    fi
    echo "Deploying for users: $USERS"
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_DIR --set rbac.users={$USERS}"
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
    read -p "Enter comma-separated list of users to clean (e.g. user1,user2): " USERS
    echo "Uninstalling release: $RELEASE_NAME"
    helm uninstall $RELEASE_NAME

    if [ -n "$USERS" ]; then
        IFS=',' read -ra USER_ARRAY <<< "$USERS"
        for user in "${USER_ARRAY[@]}"; do
            echo "Force deleting namespace: ${user}-application"
            kubectl delete namespace "${user}-application" --ignore-not-found
        done
    fi
}

while true; do
    show_menu
    read -p "Select an option [1-5]: " choice
    echo ""
    case $choice in
        1) deploy_default ;;
        2) deploy_custom ;;
        3) uninstall_release ;;
        4) uninstall_and_clean ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
    echo ""
done
