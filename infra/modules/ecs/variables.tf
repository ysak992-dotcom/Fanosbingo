variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "environment" {
  description = "Environment name. Tagged onto the EIP and instance so the instance role's AssociateAddress condition matches."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Public subnets for the ASG. Public because the instance needs direct
    internet egress (BSC RPC, Telegram, ECR) and we are deliberately not paying
    ~$32/mo for a NAT Gateway. Inbound is restricted to Cloudflare by the
    security group.
  EOT
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group admitting 443 from Cloudflare ranges only."
  type        = string
}

variable "instance_profile_name" {
  description = "Instance profile granting ECS registration, SSM access and EIP association."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the root volume and the ECS log group."
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    Graviton instance type. t4g.small (2 vCPU, 2 GiB) is the floor: measured
    steady-state footprint across the five containers plus the ECS agent and OS
    is ~1.03 GiB, and Realtime's BEAM VM alone rules out t4g.micro's 1 GiB.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "ami_id" {
  description = <<-EOT
    Pinned ECS-optimized AL2023 arm64 AMI. Empty means "use whatever AWS
    currently recommends", which is correct for a new environment and wrong for
    one that is serving traffic — see the header comment in main.tf.

    Bumped by .github/workflows/ami-bump.yml, which opens a pull request when a
    newer image is published, so the replacement lands as a reviewed change
    rather than riding along with an unrelated apply.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be empty or a valid AMI id (ami-xxxxxxxx)."
  }
}

variable "instance_count" {
  description = <<-EOT
    Instances in the ASG. 1 at launch. Setting this to 2 is most of Stage 2 —
    the ticker's advisory lock already guarantees a single game-loop caller
    across however many instances are running.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "root_volume_size" {
  description = <<-EOT
    Root EBS volume in GiB. Holds container images plus the swapfile.

    MINIMUM 30. The ECS-optimized AL2023 arm64 AMI ships a 30 GiB snapshot, and
    EBS refuses to restore a snapshot into a smaller volume — the ASG fails with
    "Volume of size 20GB is smaller than snapshot ..., expect size >= 30GB".
    Costs ~$0.80/mo more than 20 GiB.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 30
    error_message = "root_volume_size must be at least 30; the ECS-optimized AMI snapshot is 30 GiB."
  }
}

variable "swap_size_mb" {
  description = "Swapfile size in MB, as an OOM backstop during join spikes."
  type        = number
  default     = 2048
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Short by default — log ingestion is a real cost at this budget."
  type        = number
  default     = 7
}

variable "container_insights" {
  description = "Enable ECS Container Insights. Bills per metric; leave off until Stage 3."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "metric_namespace" {
  description = <<-EOT
    CloudWatch namespace the host metrics publisher writes to.

    Must match what the instance role's PutMetricData condition permits and what
    modules/monitoring alarms on, or the metrics are either rejected by IAM or
    published somewhere nothing is watching. Sourced from modules/iam in the
    environment roots rather than restated, so the three cannot drift.
  EOT
  type        = string
}
