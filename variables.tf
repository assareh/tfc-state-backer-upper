variable "notification_token" {
  description = "Used to generate the HMAC on the notification request. Read more in the documentation."
  default     = "SuperSecret"
}

variable "prefix" {
  description = "Name prefix to add to the resources"
  default     = "assareh"
}

variable "region" {
  description = "The region where the resources are created."
  default     = "us-west-2"
}

variable "tfc_token" {
  description = "Terraform Cloud token. (mark as sensitive) (TFC Organization Settings >> Teams)"
}

variable "vault_addr" {
  description = "Vault address."
}

// OPTIONAL Tags
variable "ttl" {
  description = "OPTIONAL for Cloud Custodian; value of ttl tag on cloud resources"
  default     = "1"
}

// OPTIONAL Tags
locals {
  common_tags = {
    owner              = "your-name-here"
    se-region          = "your-region-here"
    purpose            = "Back up state files"
    ttl                = var.ttl # hours
    terraform          = "true"  # true/false
    hc-internet-facing = "false" # true/false
  }
}
