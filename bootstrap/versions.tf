terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    # Only use: data.tls_certificate, to read the real TLS thumbprint of the
    # GitHub Actions OIDC endpoint instead of copying a remembered one.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Deliberately no backend block. This stack creates the S3 state bucket that
  # the rest of the repo stores its state in, so it cannot itself store state
  # there without either a chicken-and-egg cycle or a plan that wants to destroy
  # the bucket holding it. It is a one-shot run from a workstation, on local
  # state, exactly once. See README.md.
}
