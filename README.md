cd /charts/project/

helm repo update

helm dependency build

helm upgrade --install chf . -n ns-chf --create-namespace -f values.yaml

helm search repo bitnami | grep mongo