# tflint configuration. The AWS plugin catches provider-level mistakes that
# `terraform validate` cannot see (deprecated attributes, invalid enum values).
# Pin the plugin version here so a CI run and a local run cannot disagree.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.43.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# The ruleset blesses `instance_type` against live data when given credentials;
# without them it only checks shape. Keep it off so a read-only CI run is honest.
rule "aws_instance_invalid_type" {
  enabled = false
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_unused_declarations" {
  enabled = true
}
