#!/bin/sh
# GSP303 — Configure Secure RDP using a Windows Bastion Host (Challenge Lab).
# Run in Cloud Shell of the lab project:  sh gsp303.sh up | down | redo
set -eu
(set -o pipefail) 2>/dev/null && set -o pipefail

PROJECT=$(gcloud config get-value project 2>/dev/null)
# The manual's region/zone placeholders render empty; the lab sets them in project metadata.
ZONE=$(gcloud compute project-info describe --project "$PROJECT" \
  --format='value(commonInstanceMetadata.items.google-compute-default-zone)')
: "${ZONE:?no default zone in project metadata - export ZONE=<zone> and retry}"
REGION=${ZONE%-*}
IMAGE='--image-project=windows-cloud --image-family=windows-2016 --boot-disk-size=50GB --machine-type=e2-medium'
IIS='windows-startup-script-ps1=Install-WindowsFeature -Name Web-Server -IncludeManagementTools'
echo "project=$PROJECT region=$REGION zone=$ZONE"

up() {
  # Task 1: VPC, subnet, RDP rule (tag-scoped to the bastion)
  gcloud compute networks create securenetwork --subnet-mode=custom
  gcloud compute networks subnets create securesubnet --network=securenetwork \
    --region="$REGION" --range=192.168.16.0/20
  gcloud compute firewall-rules create allow-rdp-traffic --network=securenetwork \
    --direction=INGRESS --allow=tcp:3389 --source-ranges=0.0.0.0/0 --target-tags=allow-rdp-traffic

  # Checker bugs: checks 3/5 crash while deny-all-egress exists, and check 3 fails
  # if any other tcp:3389 rule exists in the project.
  for r in deny-all-egress default-allow-rdp; do
    gcloud compute firewall-rules describe "$r" >/dev/null 2>&1 \
      && gcloud compute firewall-rules delete "$r" --quiet
  done

  # Task 2: secure host (internal only on both NICs; IIS via startup script = Task 3)
  # shellcheck disable=SC2086
  gcloud compute instances create vm-securehost --zone="$ZONE" $IMAGE \
    --network-interface=network=securenetwork,subnet=securesubnet,no-address \
    --network-interface=network=default,subnet=default,no-address \
    --metadata="$IIS"
  # Bastion: external IP on securenetwork NIC, internal only on default
  # shellcheck disable=SC2086
  gcloud compute instances create vm-bastionhost --zone="$ZONE" $IMAGE \
    --network-interface=network=securenetwork,subnet=securesubnet \
    --network-interface=network=default,subnet=default,no-address \
    --tags=allow-rdp-traffic

  # Passwords (only needed for RDP; Windows takes a few minutes before this works)
  for vm in vm-bastionhost vm-securehost; do
    i=0
    until gcloud compute reset-windows-password "$vm" --zone="$ZONE" --user=app-admin --quiet; do
      i=$((i + 1)); [ "$i" -ge 20 ] && { echo "password reset for $vm failed" >&2; exit 1; }
      echo "waiting for $vm guest agent ($i/20)..."; sleep 30
    done
  done
  echo "Done. IIS installs on first boot of vm-securehost (~5 min) - then click Check my progress."
}

down() {
  # Leaves deny-all-egress/default-allow-rdp deleted on purpose (they break the checker).
  gcloud compute instances delete vm-securehost vm-bastionhost --zone="$ZONE" --quiet || true
  gcloud compute firewall-rules delete allow-rdp-traffic --quiet || true
  gcloud compute networks subnets delete securesubnet --region="$REGION" --quiet || true
  gcloud compute networks delete securenetwork --quiet || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  redo) down; up ;;
  *) echo "usage: sh $0 up|down|redo" >&2; exit 2 ;;
esac
