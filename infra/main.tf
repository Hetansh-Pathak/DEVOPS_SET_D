# Generates ../generated/service.env, consumed by compose.yaml (env_file).
# The generated file and any *.tfstate are git-ignored and must never be committed.
resource "local_file" "service_env" {
  filename             = "${path.module}/../generated/service.env"
  file_permission      = "0644"
  directory_permission = "0755"

  content = <<-EOT
    APP_NAME=${var.app_name}
    APP_ENV=${var.app_env}
    LOG_LEVEL=${var.log_level}
    PORT=${var.port}
    FAIL_MODE=${var.fail_mode}
  EOT
}
