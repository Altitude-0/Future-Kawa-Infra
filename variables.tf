variable "environment" {
  description = "Target environment (staging or production)."
  type        = string
  default     = "staging"
}

variable "k3s_version" {
  description = "Optional pinned k3s version (example: v1.31.6+k3s1). Leave empty for latest stable."
  type        = string
  default     = ""
}

variable "github_username" {
  description = "GitHub username for GHCR authentication."
  type        = string
  default     = ""
}

variable "github_token" {
  description = "GitHub Personal Access Token (PAT) with read:packages scope."
  type        = string
  default     = ""
  sensitive   = true
}

variable "central_api_image" {
  description = "Container image for the central API."
  type        = string
  default     = "ghcr.io/karimdevwm/central-api:26042026-0"
}

variable "country_api_image" {
  description = "Container image for the country-specific APIs."
  type        = string
  default     = "ghcr.io/karimdevwm/country-api:26042026-0"
}

variable "frontend_image" {
  description = "Frontend application image."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "kafka_image" {
  description = "Kafka container image."
  type        = string
  default     = "bitnamilegacy/kafka:3.7"
}

variable "kafka_ui_image" {
  description = "Kafka UI container image."
  type        = string
  default     = "provectuslabs/kafka-ui:latest"
}

variable "postgres_image" {
  description = "PostgreSQL container image."
  type        = string
  default     = "postgres:16"
}

variable "container_port" {
  description = "Application container port."
  type        = number
  default     = 80
}

variable "staging_replicas" {
  description = "Replica count for staging."
  type        = number
  default     = 1
}

variable "production_replicas" {
  description = "Replica count for production."
  type        = number
  default     = 3
}