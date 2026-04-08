# Create VMs for n users

usercount=$1
manifestdir=.
nsprefix=dev
NAMESPACE_LABEL="performance-test=true"
DOMAIN_APPS=$(oc get ingresses.config.openshift.io -o jsonpath='{.spec.domain}' cluster)

scriptdir=$(dirname $(readlink -f $0))

echo "* Creating namespaces"
for i in $(seq 1 $usercount); do
    oc new-project $nsprefix-user$i-application 1> /dev/null
    oc label ns $nsprefix-user$i-application $NAMESPACE_LABEL
done

echo "* Creating certificate"
for i in $(seq 1 $usercount); do
    oc project $nsprefix-user$i-application  1> /dev/null
    cat $scriptdir/00-certificate.yaml  | sed 's/DNSNAME/stock-'user${i}.${DOMAIN_APPS}'/g' | oc apply -n $nsprefix-user$i-application  --wait=true -f -
    oc wait --for=condition=Ready certificate/stock-cert  --timeout=120s
done

echo "* Creating configmap"
for i in $(seq 1 $usercount); do
    oc project $nsprefix-user$i-application  1> /dev/null
    cat $scriptdir/configmap.yaml  | sed 's/NAMESPACE/'$nsprefix-user$i-application'/g' | oc apply -n $nsprefix-user$i-application  -f -
done

echo "* Deploying VMs for $i"
for i in $(seq 1 $usercount); do
    oc project $nsprefix-user$i-application 1> /dev/null
    cat $manifestdir/01-vm-frontend.yaml | sed 's/DNSNAME/stock-'user${i}.${DOMAIN_APPS}'/g' | oc apply -n $nsprefix-user$i-application -f -
    oc apply -n $nsprefix-user$i-application -f $manifestdir/03-vm-database.yaml -f $manifestdir/02-vm-backend.yaml
    subctl export service --namespace $nsprefix-user$i-application  database
done


NAMESPACES=$(oc get namespaces -l "$NAMESPACE_LABEL" -o jsonpath='{.items[*].metadata.name}')
while true; do
    ALL_RUNNING=true
    
    for NS in $NAMESPACES; do
        # Get status of all VMs in the namespace
        VMS_STATUS=$(oc get vm -n "$NS" -o jsonpath='{.items[*].status.printableStatus}')
        
        for STATUS in $VMS_STATUS; do
            if [ "$STATUS" != "Running" ]; then
                ALL_RUNNING=false
                break 2 # Exit both loops to wait and retry
            fi
        done
        
        # Also check if there are no VMs at all (optional depending on use case)
        if [ -z "$VMS_STATUS" ]; then
            echo "Warning: No VMs found in namespace $NS"
        fi
    done

    if [ "$ALL_RUNNING" = true ]; then
        echo "All VMs are now Running."
        break
    else
        echo "Waiting for VMs to be Running... (Checking again in 5s)"
        sleep 5
    fi
done