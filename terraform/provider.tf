# In this demo we're using Application Default Creds instead, see this for
# details: https://cloud.google.com/docs/authentication/production
#
# TODO:  we can consider configuring it via env vars
# that were populated appropriately at runtime.
terraform {
  # The module has 0.12 syntax and is not compatible with any versions below 0.12.
  required_version = "~> 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "=3.90.0"
    }
    google-beta = {
      source  = "hashicorp/google"
      version = "=3.90.0"
    }

  }
}

provider "google" {
  project = var.project_id
} 
