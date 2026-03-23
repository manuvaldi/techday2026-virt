# Create VMs for n users

usercount=$1
manifestdir=.
nsprefix=dev
NAMESPACE_LABEL="performance-test=true"

scriptdir=$(dirname $(readlink -f $0))

echo "* Creating namespaces"
for i in $(seq 1 $usercount); do
    oc new-project $nsprefix-user$i-application 1> /dev/null
    oc label ns $nsprefix-user$i-application $NAMESPACE_LABEL
done

echo "* Creating configmap"
for i in $(seq 1 $usercount); do
    oc project $nsprefix-user$i-application 
    oc apply -f $scriptdir/configmap.yaml  
done

echo "* Deploying VMs for $i"
for i in $(seq 1 $usercount); do
    oc project $nsprefix-user$i-application 
    oc apply -f $manifestdir/01-vm-frontend.yaml -f $manifestdir/03-vm-database.yaml -f $manifestdir/02-vm-backend.yaml
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