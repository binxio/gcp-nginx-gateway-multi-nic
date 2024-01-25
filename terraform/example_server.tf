resource "google_service_account" "server" {
  project    = var.project_id
  account_id = "example-server"
}

resource "google_project_iam_member" "server_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.server.email}"
}

resource "google_project_iam_member" "server_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.server.email}"
}

resource "google_compute_instance_template" "server" {
  project     = var.project_id
  region      = "europe-west1"
  name_prefix = "example-server-"

  machine_type            = "e2-medium"
  metadata_startup_script = file("${path.module}/resources/example_server_startup_script.sh.tftpl")

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-ssd"

    auto_delete = true
  }

  can_ip_forward = false

  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.destination_vpc_servers.self_link
  }

  service_account {
    email  = google_service_account.server.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "server" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server-mig"

  base_instance_name = "example-server"

  version {
    instance_template = google_compute_instance_template.server.id
  }

  named_port {
    name = "app"
    port = 8080
  }

  update_policy {
    type            = "PROACTIVE"
    minimal_action  = "REPLACE"
    max_surge_fixed = 5
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.server_probe.id
    initial_delay_sec = 60
  }
}

# Allow health checks from instance group manager
resource "google_compute_firewall" "destination_vpc_gfe_server_ingress" {
  project     = var.project_id
  network     = google_compute_network.destination_vpc.id
  name        = "${google_compute_network.destination_vpc.name}-gfe-server-ingress"
  description = "Accept Google Front End (GFE) server traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
  target_service_accounts = [google_service_account.server.email]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_compute_health_check" "server_probe" {
  project = var.project_id
  name    = "example-server-probe"

  timeout_sec        = 5
  check_interval_sec = 10

  http_health_check {
    port_specification = "USE_FIXED_PORT"
    port               = 8080
    host               = "service.health"
    request_path       = "/healthz"
  }
}

resource "google_compute_region_autoscaler" "server" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server-autoscaler"

  target = google_compute_region_instance_group_manager.server.id

  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = 3
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

resource "google_compute_address" "server" {
  project      = var.project_id
  region       = "europe-west1"
  name         = "example-server"
  subnetwork   = google_compute_subnetwork.destination_vpc_servers.id
  address_type = "INTERNAL"
}

# Configure a friendly DNS name: server.xebia
resource "google_dns_record_set" "destination_vpc_server_xebia" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.destination_vpc_xebia.name
  name         = "example-server.xebia."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.server.address]
}


resource "google_compute_forwarding_rule" "server_http" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server-http"

  ip_address            = google_compute_address.server.address
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "INTERNAL_MANAGED"

  network    = google_compute_network.destination_vpc.id
  subnetwork = google_compute_subnetwork.destination_vpc_servers.id

  target = google_compute_region_target_http_proxy.server_http.id

  depends_on = [
    google_compute_subnetwork.destination_vpc_managed_proxy,
  ]
}

resource "google_compute_region_target_http_proxy" "server_http" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server-http"

  url_map = google_compute_region_url_map.server.id
}

resource "google_compute_region_url_map" "server" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server"

  default_service = google_compute_region_backend_service.server.id
}


resource "google_compute_region_backend_service" "server" {
  project = var.project_id
  region  = "europe-west1"
  name    = "example-server"

  load_balancing_scheme = "INTERNAL_MANAGED"

  protocol  = "HTTP"
  port_name = "app"

  connection_draining_timeout_sec = 10

  health_checks = [google_compute_health_check.server_probe.id]

  backend {
    group           = google_compute_region_instance_group_manager.server.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# Allow clients to access server port
resource "google_compute_firewall" "destination_vpc_allow_nginx_gateway_server_access" {
  project     = var.project_id
  network     = google_compute_network.destination_vpc.id
  name        = "${google_compute_network.destination_vpc.name}-nginx-server-ingress"
  description = "Accept nginx gateway server traffic"

  priority  = 4000
  direction = "INGRESS"
  source_service_accounts = [
    google_service_account.nginx_gateway.email,
  ]
  destination_ranges = [
    "${google_compute_address.server.address}/32",
  ]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# Allow load balanced server traffic to internal server port
resource "google_compute_firewall" "destination_vpc_allow_managed_proxy_access" {
  project     = var.project_id
  network     = google_compute_network.destination_vpc.id
  name        = "${google_compute_network.destination_vpc.name}-envoy-ingress"
  description = "Accept load balanced server traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    google_compute_subnetwork.destination_vpc_managed_proxy.ip_cidr_range,
  ]
  target_service_accounts = [
    google_service_account.server.email,
  ]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}