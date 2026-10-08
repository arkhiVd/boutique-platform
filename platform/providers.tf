provider "aws" {
  # us-east-1 is fixed, not variable: it matches the constant in backend.tf (a
  # backend block cannot interpolate a variable) and the account only has
  # resources in this region.
  region = "us-east-1"

  # Every resource this stack makes carries these tags. The bootstrap apply
  # role's IAM Deny keys on Project, so a resource without the tag is a
  # resource the CI pipeline cannot manage; the default block makes that
  # impossible to forget on a new resource.
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
