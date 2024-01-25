resource "google_service_account" "nginx_gateway" {
  project    = var.project_id
  account_id = "nginx-gateway"
}

resource "google_project_iam_member" "nginx_gateway_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.nginx_gateway.email}"
}

resource "google_project_iam_member" "nginx_gateway_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.nginx_gateway.email}"
}

resource "google_compute_instance_template" "nginx_gateway" {
  project     = var.project_id
  region      = "europe-west1"
  name_prefix = "nginx-gateway-"

  machine_type = "e2-medium"
  metadata_startup_script = templatefile("${path.module}/resources/nginx_gateway_startup_script.sh.tftpl", {
    load_balancer_ip = google_compute_address.nginx_gateway.address
  })

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-ssd"

    auto_delete = true
  }

  can_ip_forward = false

  # NOTE: Order of interfaces matter. DNS et al is bound to primary NIC.
  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.destination_vpc_nat.self_link
  }

  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.source_vpc_gateway.self_link
  }

  service_account {
    email  = google_service_account.nginx_gateway.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "nginx_gateway" {
  project = var.project_id
  region  = "europe-west1"
  name    = "nginx-gateway-mig"

  base_instance_name = "nginx-gateway"

  version {
    instance_template = google_compute_instance_template.nginx_gateway.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  named_port {
    name = "https"
    port = 8443
  }

  update_policy {
    type            = "PROACTIVE"
    minimal_action  = "REPLACE"
    max_surge_fixed = 5
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.nginx_gateway_probe.id
    initial_delay_sec = 60
  }
}

# Allow health checks from instance group manager
resource "google_compute_firewall" "destination_vpc_gfe_nginx_gateway_ingress" {
  project     = var.project_id
  network     = google_compute_network.destination_vpc.id
  name        = "${google_compute_network.destination_vpc.name}-gfe-nginx-ingress"
  description = "Accept Google Front End (GFE) nginx gateway traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
  target_service_accounts = [google_service_account.nginx_gateway.email]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_compute_health_check" "nginx_gateway_probe" {
  project = var.project_id
  name    = "nginx-gateway-probe"

  timeout_sec        = 5
  check_interval_sec = 10

  http_health_check {
    port_specification = "USE_FIXED_PORT"
    port               = 8080
    host               = "service.health"
    request_path       = "/healthz"
  }
}

resource "google_compute_region_autoscaler" "nginx_gateway" {
  project = var.project_id
  region  = "europe-west1"
  name    = "nginx-gateway-autoscaler"

  target = google_compute_region_instance_group_manager.nginx_gateway.id

  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = 3
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

resource "google_compute_address" "nginx_gateway" {
  project      = var.project_id
  region       = "europe-west1"
  name         = "nginx-gateway"
  subnetwork   = google_compute_subnetwork.source_vpc_gateway.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "nginx_gateway" {
  project = var.project_id
  region  = "europe-west1"
  name    = "nginx-gateway"

  ip_address  = google_compute_address.nginx_gateway.address
  ip_protocol = "TCP"
  ports = [
    "80",   # Used for HTTP forwarding
    "443",  # Used for HTTPS forwarding
    "8080", # Used for health checks
  ]
  load_balancing_scheme = "INTERNAL"

  allow_global_access = false

  network    = google_compute_network.source_vpc.id
  subnetwork = google_compute_subnetwork.source_vpc_gateway.id

  backend_service = google_compute_region_backend_service.nginx_gateway.id
}

resource "google_compute_region_backend_service" "nginx_gateway" {
  project = var.project_id
  region  = "europe-west1"
  name    = "nginx-gateway"

  protocol                        = "TCP"
  load_balancing_scheme           = "INTERNAL"
  network                         = google_compute_network.source_vpc.id
  connection_draining_timeout_sec = 10

  health_checks = [google_compute_health_check.nginx_gateway_probe.id]

  backend {
    group = google_compute_region_instance_group_manager.nginx_gateway.instance_group
  }
}

# Allow health checks from load balancer on source VPC
resource "google_compute_firewall" "source_vpc_gfe_nginx_gateway_ingress" {
  project     = var.project_id
  network     = google_compute_network.source_vpc.id
  name        = "${google_compute_network.source_vpc.name}-gfe-nginx-ingress"
  description = "Accept Google Front End (GFE) nginx traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
  target_service_accounts = [google_service_account.nginx_gateway.email]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

# Allow clients to access nginx gateway ports
resource "google_compute_firewall" "source_vpc_allow_nginx_gateway_access" {
  project     = var.project_id
  network     = google_compute_network.source_vpc.id
  name        = "${google_compute_network.source_vpc.name}-client-gateway-ingress"
  description = "Accept source VPC nginx traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    google_compute_subnetwork.source_vpc_clients.ip_cidr_range,
  ]
  target_service_accounts = [google_service_account.nginx_gateway.email]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# Configure a friendly DNS name: nginx-gateway.xebia
resource "google_dns_record_set" "source_vpc_nginx_gateway_xebia" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.source_vpc_xebia.name
  name         = "nginx-gateway.xebia."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.nginx_gateway.address]
}

# Configure references to the target services
resource "google_dns_record_set" "source_vpc_nginx_gateway_redirect_base_xebia" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.source_vpc_xebia.name
  name         = "*.xebia."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["nginx-gateway.xebia."]
}

resource "google_dns_record_set" "source_vpc_nginx_gateway_redirect_google_com" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.source_vpc_google_com.name
  name         = "google.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.nginx_gateway.address]
}

resource "google_dns_record_set" "source_vpc_nginx_gateway_redirect_base_google_com" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.source_vpc_google_com.name
  name         = "*.google.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["nginx-gateway.xebia."]
}

