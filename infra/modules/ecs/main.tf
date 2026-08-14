/**
 * ECS cluster on an EC2 capacity provider.
 *
 * The choice of EC2 over Fargate is the single largest cost decision in the
 * stack: five small Fargate tasks would be ~$53/mo against a ~$30/mo budget,
 * where one t4g.small running all five containers is ~$12/mo.
 *
 * Crucially this is NOT a dead end. Task definitions and service definitions
 * are identical either way. Moving to Fargate at Stage 3 means changing the
 * capacity provider on the service — the containers, IAM roles, log groups and
 * networking all carry over untouched.
 *
 * Availability trade at this tier, stated plainly: one instance in one AZ. An
 * instance failure is a 3-5 minute outage while the ASG replaces it. That is
 * the accepted cost of the budget, and Stage 2 (min=2 across two AZs, plus an
 * ALB) is what buys it back.
 */

data "aws_region" "current" {}

# The ECS-optimized AL2023 image for arm64 (Graviton).
#
# PINNING, and why the obvious alternative is a trap.
#
# This used to read the SSM "recommended" pointer directly, so every plan picked
# up whatever AWS had most recently published. That sounds like free patching.
# What it actually means, given the instance_refresh block below, is:
#
#   the day AWS publishes a new AMI, the NEXT apply -- for any reason at all,
#   including a one-line tag change -- replaces the instance and takes a
#   multi-minute outage nobody scheduled.
#
# On a single-instance deployment with min_healthy_percentage = 0, that is a
# real outage of a real-money game, triggered by an unrelated change. The AMI
# update itself is desirable; having it ride along invisibly with something else
# is not.
#
# So the id is pinned in the environment root, and .github/workflows/ami-bump.yml
# opens a pull request when a newer one appears. Patching stays automatic; when
# it lands stops being a surprise.
#
# ami_id = "" falls back to the recommended pointer, which is the right default
# for a brand-new environment that has no pinned value yet.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

locals {
  ecs_ami_id = try(trimspace(var.ami_id), "") == "" ? data.aws_ssm_parameter.ecs_ami.value : var.ami_id
}

# ---------------------------------------------------------------------------
# Stable address
# ---------------------------------------------------------------------------
resource "aws_eip" "app" {
  domain = "vpc"

  # The Environment tag is what the instance role's ec2:AssociateAddress
  # condition matches on, so the instance can claim this address and no other.
  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-app"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    # Container Insights bills per metric and would be a visible fraction of a
    # $30 budget. Basic ECS/EC2 metrics plus the ticker's own custom metric
    # cover what actually matters here. Enable at Stage 3.
    name  = "containerInsights"
    value = var.container_insights ? "enhanced" : "disabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster" })
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-logs" })
}

# ---------------------------------------------------------------------------
# Container instance
# ---------------------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-app-"
  image_id      = local.ecs_ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [var.security_group_id]

  # No key_name. There is deliberately no SSH path in or out — shell access is
  # SSM Session Manager, which needs no open port and is CloudTrail-logged.

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    # IMDSv2 only. IMDSv1 is the classic SSRF-to-credential-theft path.
    http_endpoint = "enabled"
    http_tokens   = "required"

    # HOP LIMIT 1, lowered from 2, because 2 was handing every container the
    # instance role.
    #
    # A packet from a bridge-networked container to 169.254.169.254 crosses the
    # docker bridge, which costs a hop -- so hop_limit = 2 is precisely what
    # makes IMDS reachable from inside a container. That includes `functions`,
    # the one process here that terminates requests from the internet. A
    # server-side request forgery in it, or any container escape, yields the EC2
    # instance profile: ECR pull, SSM, and ec2:AssociateAddress on this
    # environment's Elastic IP. It quietly undoes the task-role separation the
    # iam module is built around.
    #
    # MEASURED ON THE RUNNING dev INSTANCE (i-02939b8fd3ca83f9b) rather than
    # reasoned about, because the cost of being wrong is a cluster that cannot
    # start:
    #
    #   from inside the functions container   PUT /latest/api/token -> 200,
    #                                         56-byte token. IMDS reachable.
    #   the container's credential source     AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    #                                         = /v2/credentials/<uuid>, i.e. the
    #                                         ECS agent at 169.254.170.2 -- NOT
    #                                         IMDS. Nothing legitimate breaks.
    #   the instance role it would have got   fanosbingo-dev-ec2-instance
    #   ecs-agent container network mode      host  (one hop; unaffected by 1)
    #   ecs systemd unit                      active
    #
    # The EIP association in user_data also runs on the host, not in a
    # container, so it is likewise unaffected.
    #
    # THIS DOES NOT TAKE EFFECT ON APPLY, and not by itself afterwards either.
    #
    # Metadata options are a property of the launch template, so changing this
    # updates the template in place and creates a new version. The ASG
    # references `version = "$Latest"`, so that reference does not change --
    # Terraform sees no diff on the autoscaling group, the instance_refresh
    # block below is never triggered, and the RUNNING instance keeps hop limit 2
    # until it is replaced for some unrelated reason.
    #
    # Confirmed on the plan for this change: "1 to add, 1 to change" with the
    # ASG absent from the change set.
    #
    # So after applying, start the refresh explicitly:
    #
    #   aws autoscaling start-instance-refresh \
    #     --auto-scaling-group-name <fanosbingo-dev-app-...> \
    #     --preferences MinHealthyPercentage=0
    #
    # That is a 3-5 minute outage on a single-instance deployment -- the same
    # trade the header comment describes for an AMI bump. Do it deliberately,
    # not at peak play.
    http_put_response_hop_limit = 1

    instance_metadata_tags = "enabled"
  }

  monitoring {
    # Detailed (1-minute) monitoring costs extra; 5-minute basic is adequate
    # when the meaningful signal is a custom metric the ticker publishes itself.
    enabled = false
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    cluster_name      = aws_ecs_cluster.this.name
    region            = data.aws_region.current.region
    eip_allocation_id = aws_eip.app.allocation_id
    swap_size_mb      = var.swap_size_mb
    metric_namespace  = var.metric_namespace
    environment       = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name        = "${var.name_prefix}-app"
      Environment = var.environment
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-app-root" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name_prefix = "${var.name_prefix}-app-"

  # One instance. See the header comment on the availability trade.
  min_size         = var.instance_count
  max_size         = var.instance_count
  desired_capacity = var.instance_count

  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 180

  # Replace the instance when the launch template changes (new AMI, new user
  # data) rather than leaving a stale instance running indefinitely.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      # 0% healthy during refresh: with a single instance there is no way to
      # roll without a gap. Accepted — deploys are container-level, not
      # instance-level, so this only fires on AMI or user-data changes.
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Environment = var.environment })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    # desired_capacity drifts if the capacity provider scales; do not fight it.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "app" {
  name = "${var.name_prefix}-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.app.arn

    # Termination protection is DISABLED so `terraform destroy` works cleanly.
    # With a fixed single instance there is no scale-in event to protect against
    # anyway. Revisit at Stage 2 when the ASG actually scales.
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status = "ENABLED"
      # Pack containers tightly onto the one instance we are paying for.
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.app.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.app.name
    base              = 1
    weight            = 100
  }
}
