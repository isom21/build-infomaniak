# edr-cloudlab — orchestration targets
#
# All targets defer to ./tf-with-env which loads Tailscale auth keys
# from secrets/tailscale-authkeys.env and OpenStack creds from clouds.yaml.

TF := ./tf-with-env

.PHONY: help \
        network-init network-plan network-apply network-destroy \
        dev-init dev-plan dev-apply dev-destroy dev-console dev-status \
        lab-linux-init lab-linux-plan lab-linux-apply lab-linux-destroy \
        lab-up lab-reset lab-down \
        ts-status ts-acl ts-keys

help:
	@echo "edr-cloudlab targets"
	@echo ""
	@echo "  Networking (apply once):"
	@echo "    network-init        terraform init for shared networking"
	@echo "    network-plan        plan"
	@echo "    network-apply       apply"
	@echo "    network-destroy     destroy (will fail if VMs depend on it)"
	@echo ""
	@echo "  Dev host:"
	@echo "    dev-init            terraform init"
	@echo "    dev-plan            plan"
	@echo "    dev-apply           apply (creates dev VM, ~5 min for cloud-init)"
	@echo "    dev-status          show running instance status"
	@echo "    dev-console         tail recent console log"
	@echo "    dev-destroy         destroy"
	@echo ""
	@echo "  Linux lab:"
	@echo "    lab-linux-{init,plan,apply,destroy}"
	@echo ""
	@echo "  Lab convenience:"
	@echo "    lab-up              apply both labs"
	@echo "    lab-reset           taint + apply (rebuild from image)"
	@echo "    lab-down            destroy both labs"
	@echo ""
	@echo "  Tailscale:"
	@echo "    ts-status           list current tailnet devices"
	@echo "    ts-acl              show live ACL policy"
	@echo "    ts-keys             list auth keys"

# ---- networking ----
network-init:
	$(TF) terraform/network init
network-plan:
	$(TF) terraform/network plan
network-apply:
	$(TF) terraform/network apply -auto-approve -parallelism=1
network-destroy:
	$(TF) terraform/network destroy

# ---- dev host ----
dev-init:
	$(TF) terraform/dev init
dev-plan:
	$(TF) terraform/dev plan
dev-apply:
	$(TF) terraform/dev apply -auto-approve
dev-destroy:
	$(TF) terraform/dev destroy
dev-status:
	@OS_CLIENT_CONFIG_FILE=/mnt/d/priv/code/PCU-9UAH2PR-clouds.yaml \
	  openstack --os-cloud PCP-9UAH2PR-dc4-a server show dev -f yaml 2>/dev/null \
	  | grep -E '^(name|status|addresses|OS-EXT-STS:vm_state|created):' || echo "no instance named 'dev'"
dev-console:
	@OS_CLIENT_CONFIG_FILE=/mnt/d/priv/code/PCU-9UAH2PR-clouds.yaml \
	  openstack --os-cloud PCP-9UAH2PR-dc4-a console log show dev | tail -80

# ---- Linux lab ----
lab-linux-init:
	$(TF) terraform/lab-linux init
lab-linux-plan:
	$(TF) terraform/lab-linux plan
lab-linux-apply:
	$(TF) terraform/lab-linux apply -auto-approve
lab-linux-destroy:
	$(TF) terraform/lab-linux destroy

lab-up: lab-linux-apply
lab-down: lab-linux-destroy
lab-reset:
	$(TF) terraform/lab-linux apply -replace=openstack_compute_instance_v2.lab -auto-approve

# ---- Tailscale ----
ts-status:
	@TS=$$(grep -m1 '^TS_API_TOKEN=' secrets/*.env 2>/dev/null | cut -d= -f2-) ; \
	  if [ -z "$$TS" ]; then echo "Set TS_API_TOKEN in secrets/tailscale-api.env" ; exit 1 ; fi ; \
	  curl -sS -H "Authorization: Bearer $$TS" \
	    https://api.tailscale.com/api/v2/tailnet/-/devices \
	    | python3 -c 'import json,sys; [print(f"{d[\"hostname\"]:20} {d[\"addresses\"][0]:20} tags={d.get(\"tags\",[])}") for d in json.load(sys.stdin)["devices"]]'
ts-acl:
	@TS=$$(grep -m1 '^TS_API_TOKEN=' secrets/*.env 2>/dev/null | cut -d= -f2-) ; \
	  curl -sS -H "Authorization: Bearer $$TS" -H 'Accept: application/hujson' \
	    https://api.tailscale.com/api/v2/tailnet/-/acl
ts-keys:
	@TS=$$(grep -m1 '^TS_API_TOKEN=' secrets/*.env 2>/dev/null | cut -d= -f2-) ; \
	  curl -sS -H "Authorization: Bearer $$TS" \
	    https://api.tailscale.com/api/v2/tailnet/-/keys \
	    | python3 -m json.tool
