provider "aws" {
  region = var.aws_region

  # The same tags the platform stack uses, for the same reason: the apply role's
  # IAM Deny below keys on Project, so a role that exists without the tag is a
  # role the apply role cannot touch — including the ones this stack makes.
  default_tags {
    tags = {
      Project     = "boutique-platform"
      Environment = "lab"
      ManagedBy   = "Terraform"
      Owner       = "aravindakrishnan"
      CostControl = "destroy-after-test"
    }
  }
}

provider "tls" {}
