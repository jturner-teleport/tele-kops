.PHONY: bootstrap up down pause resume delete clean-cluster kubeconfig

## bootstrap  Run once to create S3 buckets and DynamoDB tables
bootstrap:
	@bash bootstrap/bootstrap.sh

## up         Spin up the kops cluster and deploy Teleport
up:
	@bash scripts/spin-up.sh

## down       Tear down the cluster (data persists in DynamoDB + S3)
down:
	@bash scripts/spin-down.sh

## pause      Scale workers to 0, master keeps running (~$1/day)
pause:
	@bash scripts/pause.sh

## resume     Scale workers back up, pods reschedule in ~2-3 min
resume:
	@bash scripts/resume.sh

## delete        Nuclear teardown: removes cluster AND all persistent data (S3, DynamoDB)
delete:
	@bash scripts/delete.sh

## clean-cluster  Delete orphaned EC2 resources when make up fails (preserves data)
clean-cluster:
	@bash scripts/clean-cluster.sh

## kubeconfig  Refresh kubectl credentials (token expires after ~18h)
kubeconfig:
	@bash scripts/kubeconfig.sh

## help       Show this help
help:
	@grep -E '^##' Makefile | sed 's/## /  /'
