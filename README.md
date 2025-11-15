cd /charts/project/

helm repo update

helm dependency build

helm upgrade --install chf . -n ns-chf --create-namespace -f values.yaml --set-file chf.sftp.authorizedKeys=charts/chf/files/authorized_keys

helm search repo bitnami | grep mongo

helm template chf . -n ns-chf -f values.yaml | kubectl apply --dry-run=client -f -

Prerequists:
1) Private key of SFTP Uploader Cronjob must be found in this path
charts/project/charts/chf/files/authorized_keys