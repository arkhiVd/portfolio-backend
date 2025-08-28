variable "ip_hash_secret" {
  description = "A secret salt used for hashing visitor IP addresses."
  type        = string
  sensitive   = true
}
variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "ap-south-1"
  
}