ansible-galaxy collection install -r requirements.yml

pip3 install -r requirements.txt

# pip3 install -r ~/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt

# Govc, requires sudo 
curl -L "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | sudo tar -C "/usr/local/bin" -xvz govc