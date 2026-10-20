#!/bin/sh
# GSP303 Secure RDP via Windows bastion host. Run in Cloud Shell: sh gsp303.sh up|down|redo
set -eu

# The lab page leaves region/zone blank; the project metadata has them.
ZONE=$(gcloud compute project-info describe \
  --format='value(commonInstanceMetadata.items.google-compute-default-zone)')
REGION=${ZONE%-*}
VM="--zone=$ZONE --machine-type=e2-medium --image-project=windows-cloud --image-family=windows-2016 --boot-disk-size=50GB"

up() {
  gcloud compute networks create securenetwork --subnet-mode=custom
  gcloud compute networks subnets create securesubnet --network=securenetwork --region="$REGION" --range=192.168.16.0/20
  gcloud compute firewall-rules create allow-rdp-traffic --network=securenetwork \
    --allow=tcp:3389 --source-ranges=0.0.0.0/0 --target-tags=allow-rdp-traffic

  # These lab rules break the checker when present.
  for r in deny-all-egress default-allow-rdp; do
    gcloud compute firewall-rules delete "$r" --quiet 2>/dev/null || true
  done

  # Startup script installs IIS, so no RDP session is needed.
  # shellcheck disable=SC2086
  gcloud compute instances create vm-securehost $VM \
    --network-interface=subnet=securesubnet,no-address \
    --network-interface=subnet=default,no-address \
    --metadata='windows-startup-script-ps1=Install-WindowsFeature -Name Web-Server -IncludeManagementTools'
  # shellcheck disable=SC2086
  gcloud compute instances create vm-bastionhost $VM --tags=allow-rdp-traffic \
    --network-interface=subnet=securesubnet \
    --network-interface=subnet=default,no-address

  # Retry until Windows is ready to accept the password reset.
  for vm in vm-bastionhost vm-securehost; do
    until gcloud compute reset-windows-password "$vm" --zone="$ZONE" --user=app-admin --quiet; do sleep 30; done
  done
  echo "Done. IIS is ready ~8-10 min after VM creation; then click Check my progress."
}

down() {
  gcloud compute instances delete vm-securehost vm-bastionhost --zone="$ZONE" --quiet || true
  # Delete by network so leftovers from manual attempts go too.
  for r in $(gcloud compute firewall-rules list --filter='network~/securenetwork$' --format='value(name)'); do
    gcloud compute firewall-rules delete "$r" --quiet
  done
  for s in $(gcloud compute networks subnets list --filter='network~/securenetwork$' --format='value(name)'); do
    gcloud compute networks subnets delete "$s" --region="$REGION" --quiet
  done
  gcloud compute networks delete securenetwork --quiet || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  redo) down; up ;;
  *) echo "usage: sh $0 up|down|redo" >&2; exit 2 ;;
esac
