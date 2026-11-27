output "service_env_path" {
  description = "Path of the generated environment file."
  value       = local_file.service_env.filename
}
