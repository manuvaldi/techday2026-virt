podman run -it --rm \
  --name devops-shell \
  --userns=keep-id \
  -v /tmp:/tmp:Z \
  devops-toolbox:latest
