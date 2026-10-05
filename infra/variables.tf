variable "subscription_id" {
  description = "Azure subscription that receives the demo resources."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Region that offers API Management Basic v2, Container Apps, and PostgreSQL flexible server."
  type        = string
  default     = "westus3"
  nullable    = false
}

variable "name_prefix" {
  description = "Short name stem; a random suffix is appended to keep global names unique."
  type        = string
  default     = "hsi"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.name_prefix))
    error_message = "Use 2-10 lowercase letters or digits, starting with a letter."
  }
}

variable "publisher_email" {
  description = "API Management publisher contact."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.publisher_email))
    error_message = "publisher_email must be an email address."
  }
}

variable "operator_ip" {
  description = "Public IPv4 address allowed through the PostgreSQL firewall to seed the database."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrhost("${var.operator_ip}/32", 0))
    error_message = "operator_ip must be a single IPv4 address."
  }
}
