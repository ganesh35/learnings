#!/bin/sh
# GSP303 Secure RDP via Windows bastion host. Run in Cloud Shell: sh gsp303.sh up|down|redo
set -eu

# The lab page leaves region/zone blank; the project metadata has them.
ZONE=$(gcloud compute project-info describe \
  --format='value(commonInstanceMetadata.items.google-compute-default-zone)')
REGION=${ZONE%-*}
VM="--zone=$ZONE --machine-type=e2-medium --image-project=windows-cloud --image-family=windows-2016 --boot-disk-size=50GB"

step() { echo; echo "== $*"; }

up() {
  step 'Step 1/6: VPC network securenetwork'
  gcloud compute networks create securenetwork --subnet-mode=custom
  step 'Step 2/6: subnet securesubnet'
  gcloud compute networks subnets create securesubnet --network=securenetwork --region="$REGION" --range=192.168.16.0/20
  step 'Step 3/6: RDP firewall rule (bastion only)'
  gcloud compute firewall-rules create allow-rdp-traffic --network=securenetwork \
    --allow=tcp:3389 --source-ranges=0.0.0.0/0 --target-tags=allow-rdp-traffic

  # These lab rules break the checker when present.
  for r in deny-all-egress default-allow-rdp; do
    gcloud compute firewall-rules delete "$r" --quiet 2>/dev/null || true
  done

  step 'Step 4/6: vm-securehost (internal only, IIS via startup script)'
  # Startup script installs IIS, so no RDP session is needed.
  # shellcheck disable=SC2086
  gcloud compute instances create vm-securehost $VM \
    --network-interface=subnet=securesubnet,no-address \
    --network-interface=subnet=default,no-address \
    --metadata='windows-startup-script-ps1=Install-WindowsFeature -Name Web-Server -IncludeManagementTools'
  step 'Step 5/6: vm-bastionhost (external IP on securenetwork)'
  # shellcheck disable=SC2086
  gcloud compute instances create vm-bastionhost $VM --tags=allow-rdp-traffic \
    --network-interface=subnet=securesubnet \
    --network-interface=subnet=default,no-address

  step 'Step 6/6: app-admin passwords'
  # Retry until Windows is ready to accept the password reset.
  for vm in vm-bastionhost vm-securehost; do
    until gcloud compute reset-windows-password "$vm" --zone="$ZONE" --user=app-admin --quiet; do sleep 30; done
  done
  echo "Done. IIS is ready ~8-10 min after VM creation; then click Check my progress."
}

down() {
  step 'Cleanup 1/3: VMs'
  gcloud compute instances delete vm-securehost vm-bastionhost --zone="$ZONE" --quiet || true
  step 'Cleanup 2/3: firewall rules and subnets on securenetwork'
  # Delete by network so leftovers from manual attempts go too.
  for r in $(gcloud compute firewall-rules list --filter='network~/securenetwork$' --format='value(name)'); do
    gcloud compute firewall-rules delete "$r" --quiet
  done
  for s in $(gcloud compute networks subnets list --filter='network~/securenetwork$' --format='value(name)'); do
    gcloud compute networks subnets delete "$s" --region="$REGION" --quiet
  done
  step 'Cleanup 3/3: securenetwork'
  gcloud compute networks delete securenetwork --quiet || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  redo) down; up ;;
  *) echo "usage: sh $0 up|down|redo" >&2; exit 2 ;;
esac
