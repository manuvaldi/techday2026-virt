# How to deploy in RH Demo system

1)  Provision a VMWare Demo system environment: https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/vmware-ibm.sandbox-vmware.prod

2) Provision a Azure Black environment: https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/azure-gpte.open-environment-azure-subscription.prod

3) `cd deploy/infra-playbooks/`

4) copy and/or fill `vars/secrets.yaml` file with envs parameters and values 

5) run playbook: `ansible-playbook playbook.yaml -e @./vars/secrets.yaml`



# How to deploy 3 tier demo app

1) `cd manifests`

2) `oc apply -f 01-vm-frontend.yaml -f 02-vm-backend.yaml -f 03-vm-database.yaml`

NOTE:
- You may need to create a certificate before deploying the route, or modify the route configuration to bypass the certificate requirement (route is in `01-vm-frontend.yaml`)

