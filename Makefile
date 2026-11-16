ENV ?= dev
TF_DIR := terraform/envs/$(ENV)

.PHONY: test fmt fmt-check lint validate init plan apply

test:
	python -m pytest

fmt:
	terraform fmt -recursive terraform

fmt-check:
	terraform fmt -check -recursive terraform

lint:
	tflint --init && tflint --recursive
	checkov -d terraform --config-file .checkov.yaml

validate:
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate

init:
	terraform -chdir=$(TF_DIR) init -backend-config=backend.hcl -input=false

plan:
	terraform -chdir=$(TF_DIR) plan -input=false -out=tfplan

apply:
	terraform -chdir=$(TF_DIR) apply -input=false tfplan
