#!/bin/bash

# https://blog.tekspace.io/setup-kubernetes-cluster-using-k3s-metallb-letsencrypt-on-bare-metal/

# DEPENDENCIES (enable for first run)
sudo snap --wait install helm --classic
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add dask https://helm.dask.org/
helm repo add jetstack https://charts.jetstack.io 
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo add harbor https://helm.goharbor.io
helm repo add drone https://charts.drone.io
helm repo update

# FIREWALL
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22               # SSH
sudo ufw allow 80               # HTTP
sudo ufw allow 443              # HTTPS
sudo ufw allow 6443/tcp         # K3s agent nodes	Kubernetes API Server
sudo ufw allow 8472/udp         # K3s server and agent nodes	Required only for Flannel VXLAN
sudo ufw allow 10250/tcp        # K3s server and agent nodes	Kubelet metrics
sudo ufw allow 2379:2380/tcp    # K3s server nodes	Required only for HA with embedded etcd
sudo ufw enable

# HARDWARE
echo vm.swappiness=0 | sudo tee -a /etc/sysctl.conf # ONLY USE SWAP IF OUT OF RAM

# K3S (without LB / Traefik)
EXECOPTS='server --disable servicelb --disable traefik'
EXECOPTS=${EXECOPTS}' --protect-kernel-defaults=true'
EXECOPTS=${EXECOPTS}' --secrets-encryption=true'
EXECOPTS=${EXECOPTS}' --kube-apiserver-arg=oidc-issuer-url=https://auth.badbunch.net/auth/realms/admin'
EXECOPTS=${EXECOPTS}' --kube-apiserver-arg=oidc-client-id=k8s'
EXECOPTS=${EXECOPTS}' --kube-apiserver-arg=oidc-username-claim=email'
EXECOPTS=${EXECOPTS}' --kube-apiserver-arg=oidc-groups-claim=groups'
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="$EXECOPTS" sh -s -
sleep 30
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
# kubectl config view --raw > $HOME/.kube/config
# needed to connect nodes from outside and for them to be able to function properly
kubectl apply -f https://raw.githubusercontent.com/alekc-go/flannel-fixer/master/deployment.yaml


# Install Metal LB
kubectl apply --wait -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/namespace.yaml
kubectl apply --wait -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/metallb.yaml
kubectl create --wait secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply --wait -f metallb-config.yaml

# NGINX - INGRESS
helm install --wait -n ingress --create-namespace ingress ingress-nginx/ingress-nginx # --values nginx-ingress.yaml
# helm uninstall -n ingress  ingress

# CERT - MANAGER
kubectl apply --wait -f https://github.com/jetstack/cert-manager/releases/download/v1.2.0/cert-manager.yaml
kubectl create --wait -f issuer-staging.yaml
kubectl create --wait -f issuer-prod.yaml

# KEYCLOAK
helm install --wait keycloak -n keycloak --create-namespace codecentric/keycloak --values keycloak.yaml

# HARBOR
helm install --wait harbor -n harbor --create-namespace bitnami/harbor --values harbor.yaml
# helm uninstall -n harbor  harbor

# DRONE
helm install --wait drone-runner drone/drone-runner-kube --namespace drone --create-namespace --values drone-runner.yaml
# helm uninstall -n drone  drone
# helm uninstall -n drone  drone-runner

# DASKHUB (JUPYTERLABS + DASK GATEWAY)
kubectl apply -f dask-pvc.yaml
helm upgrade --wait -n dhub --create-namespace --install --render-subchart-notes dhub dask/daskhub --namespace=dhub --values=dask.yaml --timeout=30m
# helm uninstall -n dhub dhub

# LONGHORD
# kubectl apply -f longhorn.yaml

# SYSTEM SUBDOMAINS
kubectl apply --wait -f ingress.yaml

# NVIDIA/GPU Support
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.9.0/nvidia-device-plugin.yml

