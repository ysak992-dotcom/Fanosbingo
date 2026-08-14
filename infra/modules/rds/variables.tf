variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated subnet ids for the DB subnet group. Must span two AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS requires subnets in at least two availability zones."
  }
}

variable "security_group_id" {
  description = "Security group permitting 5432 from the application security group only."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting storage and the managed master password secret."
  type        = string
}

variable "engine_version" {
  description = <<-EOT
    PostgreSQL version. Major-only ("16") lets RDS pick the current minor and
    avoids an apply failing because a pinned minor was retired. Must match the
    parameter group family (postgres16).
  EOT
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = <<-EOT
    Instance class. db.t4g.micro (2 vCPU burstable, 1 GiB) is sized for ~200
    users and ~60 concurrent players. Step up to db.t4g.small before ~2000 users
    or if CPU credits start depleting.
  EOT
  type        = string
  default     = "db.t4g.micro"
}

variable "database_name" {
  description = "Initial database name. Also set as cron.database_name."
  type        = string
  default     = "fanosbingo"
}

variable "master_username" {
  description = "Master username. The password is generated and rotated by RDS in Secrets Manager."
  type        = string
  default     = "fanosadmin"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB. 20 is the minimum billable size."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = <<-EOT
    Storage autoscaling ceiling in GiB. Set above allocated_storage so a slow
    disk-fill grows instead of taking writes offline. Keep the ceiling modest:
    runaway growth is a cost incident as well as a symptom.
  EOT
  type        = number
  default     = 50
}

variable "max_slot_wal_keep_mb" {
  description = <<-EOT
    Cap on WAL retained for an inactive replication slot, in MB. Prevents a dead
    Realtime container from filling the disk. 0 means unlimited — do not use 0.
  EOT
  type        = number
  default     = 2048

  validation {
    condition     = var.max_slot_wal_keep_mb >= 512
    error_message = "max_slot_wal_keep_mb must be at least 512; 0 (unlimited) risks a disk-full outage."
  }
}

variable "backup_retention_period" {
  description = "Days of automated backups and point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1
    error_message = "backup_retention_period must be at least 1; 0 disables PITR entirely."
  }
}

variable "backup_window" {
  description = "Daily backup window, UTC. Chosen for low traffic in East Africa (UTC+3)."
  type        = string
  default     = "01:00-02:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window, UTC. Must not overlap backup_window."
  type        = string
  default     = "Tue:02:30-Tue:03:30"
}

variable "multi_az" {
  description = <<-EOT
    Multi-AZ standby. Roughly doubles the instance cost, so it is off at launch
    and becomes the first thing to enable at Stage 2 (>500 users, or the first
    real outage, or monthly volume above ~$5k).
  EOT
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block accidental deletion. Keep true in prod; false in dev so destroy works."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Never true in prod."
  type        = bool
  default     = false
}

variable "final_snapshot_suffix" {
  description = "Suffix making the final snapshot identifier unique across recreations."
  type        = string
  default     = "v1"
}

variable "apply_immediately" {
  description = "Apply modifications at once rather than in the maintenance window. Disruptive in prod."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = <<-EOT
    Performance Insights. Free at 7-day retention, but NOT supported on every
    burstable class — leave false on db.t4g.micro unless you have confirmed
    support for your chosen class, or the apply will fail.
  EOT
  type        = bool
  default     = false
}

variable "enabled_cloudwatch_logs_exports" {
  description = <<-EOT
    Postgres log types exported to CloudWatch. Each one gets a Terraform-managed
    log group so retention and encryption are set deliberately rather than left
    at the "never expires, no CMK" group RDS creates on its own.

    Adding a type here creates its group on the next apply. Removing one leaves
    the group behind on purpose -- the logs already written should outlive the
    decision to stop writing more.
  EOT
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "log_retention_days" {
  description = <<-EOT
    Retention for the exported Postgres logs. 7 matches /ecs/<prefix>, which is
    long enough to investigate an incident over a weekend and short enough that
    a chatty log_min_duration_statement cannot become a line item.
  EOT
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "real_money" {
  description = <<-EOT
    Whether this environment holds real player money.

    NOT a cosmetic label. It is the switch the durability settings are checked
    against: with it true, an apply FAILS unless backup retention, Multi-AZ,
    deletion protection and the final snapshot are all set to what a ledger of
    real balances requires. See the precondition in main.tf.

    WHY IT EXISTS. environments/prod/main.tf carried a comment reading "ONE, AND
    IT MUST BECOME 7 BEFORE THE FIRST REAL DEPOSIT", and the same file gated
    multi_az and the instance count on the same promise. Three settings, one
    remembered intention, enforced by nobody -- and the trigger was named as an
    EVENT ("the first real deposit"), which is exactly the kind of thing that
    happens on a Tuesday without anyone rereading a Terraform comment.

    This turns the promise into a variable. It cannot make anyone flip it before
    taking a deposit; it makes flipping it impossible to do HALFWAY, which is
    the failure that would actually cost money -- believing prod is durable
    because somebody changed one of the three.
  EOT
  type        = bool
  default     = false
}

variable "accept_single_az_risk" {
  description = <<-EOT
    Acknowledge running a real-money database in ONE availability zone.

    Only consulted when real_money is true. Multi-AZ roughly doubles the RDS
    instance cost, which is a real constraint on this budget -- so it is not
    forced. What is forced is that somebody chose it: without this, real_money
    and multi_az = false is indistinguishable from an oversight.

    Setting it true accepts: an AZ failure takes the ledger offline until a
    manual restore. The nightly pg_dump to S3 under Object Lock bounds how much
    is LOST; nothing bounds how long it is DOWN. Revisit when the customer base
    justifies the second instance.
  EOT
  type        = bool
  default     = false
}
