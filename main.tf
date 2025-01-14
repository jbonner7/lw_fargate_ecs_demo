provider "aws" {
  region                  = var.aws_region
  profile                 = var.aws_profile
  shared_credentials_file = "~/.aws/credentials"
}

### Network

# Fetch AZs in the current region
data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block = "172.17.0.0/16"

  tags = {
    Name = "${var.userid}-fargate-ecs-vpc"
  }
}

# Create var.az_count private subnets, each in a different AZ
resource "aws_subnet" "private" {
  count             = var.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.main.id
}

# Create var.az_count public subnets, each in a different AZ
resource "aws_subnet" "public" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id
  map_public_ip_on_launch = true
}

# IGW for the public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# Route the public subnet traffic through the IGW
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.main.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

# Create a NAT gateway with an EIP for each private subnet to get internet connectivity
resource "aws_eip" "gw" {
  count      = var.az_count
  vpc        = true
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_nat_gateway" "gw" {
  count         = var.az_count
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gw.*.id, count.index)
}

# Create a new route table for the private subnets
# And make it route non-local traffic through the NAT gateway to the internet
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gw.*.id, count.index)
  }
}

# Explicitely associate the newly created route tables to the private subnets (so they don't default to the main route table)
resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

### Security

# ALB Security group
# This is the group you need to edit if you want to restrict access to your application
resource "aws_security_group" "lb" {
  name        = "${var.userid}-fargate-ecs-alb"
  description = "controls access to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.userid}-fargate-ecs-tasks"
  description = "allow inbound access from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "tcp"
    from_port       = var.app_port
    to_port         = var.app_port
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### ALB

resource "aws_alb" "main" {
  name            = "${var.userid}-fargate-ecs-chat"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_alb_target_group" "app" {
  name        = "${var.userid}-fargate-ecs-chat"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.main.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.app.id
    type             = "forward"
  }
}

### ECS Cluster

resource "aws_ecs_cluster" "main" {
  name = "${var.userid}-fargate-ecs-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "app"
  execution_role_arn       = aws_iam_role.ExecutionRole.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_task_cpu
  memory                   = var.fargate_task_memory

  container_definitions = <<DEFINITION
[
  {
    "cpu": ${var.fargate_container_cpu},
    "image": "lacework/datacollector:latest-sidecar",
    "memory": ${var.fargate_container_memory},
    "name": "datacollector-sidecar",
    "networkMode": "awsvpc",
    "portMappings": [],
    "essential": false,
  	"environment": [],
  	"mountPoints": [],
  	"volumesFrom": [],
  	"logConfiguration": {
  		"logDriver": "awslogs",
  		"options": {
  			"awslogs-group": "${var.cw-log-group}-${var.userid}",
  			"awslogs-region": "${var.aws_region}",
  			"awslogs-stream-prefix": "ecs"
  		}
  	}
  },
  {
    "cpu": ${var.fargate_container_cpu},
    "image": "${var.app_image}",
    "memory": ${var.fargate_container_memory},
    "name": "app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": ${var.app_port},
        "hostPort": ${var.app_port}
      }
    ],
    "essential": true,
    "entryPoint": [
      "/var/lib/lacework-backup/lacework-sidecar.sh"
    ],
    "command": [
       "nginx",
       "-g",
       "daemon off;"
    ],
    "environment": [
      {
        "name": "LaceworkAccessToken",
        "value": "${var.lw_token}"
      },
      {
        "name": "LaceworkServerUrl",
        "value": "${var.lw_serverurl}"
      }
    ],
    "mountPoints": [],
    "volumesFrom": [
      {
        "sourceContainer": "datacollector-sidecar",
        "readOnly": true
      }
    ],
    "dependsOn": [
      {
        "containerName": "datacollector-sidecar",
        "condition": "SUCCESS"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${var.cw-log-group}-${var.userid}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITION
}

resource "aws_cloudwatch_log_group" "datacollector-sidecar-demo" {
  name = "${var.cw-log-group}-${var.userid}"
}

resource "aws_ecs_service" "main" {
  name            = "${var.userid}-fargate-ecs-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"
  depends_on      = [
    aws_alb_listener.front_end,
    aws_iam_role.ExecutionRole
  ]

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.id
    container_name   = "app"
    container_port   = var.app_port
  }
}
