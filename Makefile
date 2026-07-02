.PHONY: check launch pause resume status logs destroy vm-up k8s-apply gpu-node

check:
	python3 scripts/manifest_env.py --check
	python3 -m compileall -q app scripts examples k8s
	@for f in scripts/*.sh k8s/scripts/*.sh; do bash -n "$$f"; done

launch:
	bash scripts/launch.sh

pause:
	bash scripts/pause.sh

resume:
	bash scripts/resume.sh

status:
	bash scripts/status.sh

logs:
	bash scripts/logs.sh

destroy:
	bash scripts/destroy.sh

vm-up:
	bash scripts/vm-up.sh

k8s-apply:
	bash scripts/k8s-apply.sh

gpu-node:
	bash scripts/add-gpu-node.sh
