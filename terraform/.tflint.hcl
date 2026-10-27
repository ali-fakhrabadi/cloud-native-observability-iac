# `make terraform-lint` runs tflint over every module and environment: all Terraform
# language rules (naming, documented and typed variables, unused declarations, module
# structure) plus the AWS ruleset (invalid instance types, deprecated arguments, ...).
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
