variable "ip_hash_secret" {
  description = "A secret salt used for hashing visitor IP addresses."
  type        = string
  sensitive   = true # This tells Terraform not to show the value in logs
}