cd /charts/project/

helm repo update

helm dependency build

helm upgrade --install chf . -n ns-chf --create-namespace -f values.yaml --set-file chf.cdr.uploader.sftp.auth.privatekey=charts/chf/files/id_ed25519

helm search repo bitnami | grep mongo

helm template chf . -n ns-chf -f values.yaml | kubectl apply --dry-run=client -f -

ssh-keyscan -p 8654 10.0.20.42 | awk '{print "[10.0.20.42]:8654",$2,$3}' > known_hosts

packages for cronjob image: alpine:3.20
apk add --no-cache zip openssh-client sshpass bash && exec bash -x /scripts/uploader.sh

Prerequists:
1) Private key of SFTP Uploader Cronjob must be found in this path
charts/project/charts/chf/files/id_ed25519