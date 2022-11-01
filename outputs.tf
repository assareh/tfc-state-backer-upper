output "webhook_url" {
  description = "Webhook URL to add to workspace notifications"
  value       = aws_api_gateway_deployment.webhook.invoke_url
}