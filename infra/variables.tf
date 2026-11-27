variable "app_name" {
  description = "Application name written to APP_NAME."
  type        = string
  default     = "campus-library"

  validation {
    condition     = length(trimspace(var.app_name)) > 0
    error_message = "app_name must not be empty."
  }
}

variable "app_env" {
  description = "Deployment environment written to APP_ENV."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.app_env)
    error_message = "app_env must be one of: dev, test, staging, prod."
  }
}

variable "log_level" {
  description = "Application log level written to LOG_LEVEL."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "port" {
  description = "TCP port the application listens on (unprivileged range)."
  type        = number
  default     = 8080

  validation {
    condition     = var.port >= 1024 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number between 1024 and 65535."
  }
}

variable "fail_mode" {
  description = "Set to 1 to make /readyz return 503 (controlled incident only)."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1], var.fail_mode)
    error_message = "fail_mode must be 0 or 1."
  }
}
