# Postfix for naming
resource "random_id" "id" {
  byte_length = 1
}

# Required services
# Required to configure VPC and allow running of VMs
resource "google_project_service" "compute_googleapis_com" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# Required to add service accounts
resource "google_project_service" "iam_googleapis_com" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

# Required to configure private DNS zones
resource "google_project_service" "dns_googleapis_com" {
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

# Networking
# 10.0.0.0/24   => Source VPC Clients
# 10.0.1.0/24   => Source VPC Gateways
# 10.0.0.0/24   => Destination VPC NAT
# 10.0.10.0/24  => Destination VPC Servers
# 10.10.0.0/24  => Destination VCP Managed load balancer proxy-only subnet
resource "google_compute_network" "source_vpc" {
  project = var.project_id
  name    = "source-vpc-${random_id.id.hex}"

  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "source_vpc_clients" {
  project       = var.project_id
  network       = google_compute_network.source_vpc.id
  name          = "${google_compute_network.source_vpc.name}-clients"
  region        = "europe-west1"
  ip_cidr_range = "10.0.0.0/24"

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "source_vpc_gateway" {
  project       = var.project_id
  network       = google_compute_network.source_vpc.id
  name          = "${google_compute_network.source_vpc.name}-gateway"
  region        = "europe-west1"
  ip_cidr_range = "10.0.1.0/24"

  private_ip_google_access = true
}

resource "google_compute_network" "destination_vpc" {
  project = var.project_id
  name    = "destination-vpc-${random_id.id.hex}"

  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "destination_vpc_nat" {
  project       = var.project_id
  network       = google_compute_network.destination_vpc.id
  name          = "${google_compute_network.destination_vpc.name}-nat"
  region        = "europe-west1"
  ip_cidr_range = "10.0.0.0/24"

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "destination_vpc_servers" {
  project       = var.project_id
  network       = google_compute_network.destination_vpc.id
  name          = "${google_compute_network.destination_vpc.name}-servers"
  region        = "europe-west1"
  ip_cidr_range = "10.0.10.0/24"

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "destination_vpc_managed_proxy" {
  project       = var.project_id
  network       = google_compute_network.destination_vpc.id
  name          = "${google_compute_network.destination_vpc.name}-envoy"
  region        = "europe-west1"
  ip_cidr_range = "10.10.0.0/24"

  purpose = "REGIONAL_MANAGED_PROXY"
  role    = "ACTIVE"
}

# Allow IAP access for source VPC
resource "google_compute_firewall" "source_vpc_allow_iap_access" {
  project     = var.project_id
  network     = google_compute_network.source_vpc.id
  name        = "${google_compute_network.source_vpc.name}-iap-access"
  description = "Allow incoming access from Identity Aware Proxy subnet block 35.235.240.0/20 for SSH, RDP and WinRM"

  priority    = 4000
  direction   = "INGRESS"
  target_tags = ["allow-iap-access"]

  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389", "5986"]
  }
}

# Configure private DNS zone for source VPC
resource "google_dns_managed_zone" "source_vpc_xebia" {
  project  = var.project_id
  name     = "${google_compute_network.source_vpc.name}-xebia"
  dns_name = "xebia."

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.source_vpc.id
    }
  }

  depends_on = [
    google_project_service.dns_googleapis_com
  ]
}

resource "google_dns_managed_zone" "source_vpc_google_com" {
  project  = var.project_id
  name     = "${google_compute_network.source_vpc.name}-google-com"
  dns_name = "google.com."

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.source_vpc.id
    }
  }

  depends_on = [
    google_project_service.dns_googleapis_com
  ]
}

# Configure private DNS zone for destination VPC
resource "google_dns_managed_zone" "destination_vpc_xebia" {
  project  = var.project_id
  name     = "${google_compute_network.destination_vpc.name}-xebia"
  dns_name = "xebia."

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.destination_vpc.id
    }
  }

  depends_on = [
    google_project_service.dns_googleapis_com
  ]
}


# Enable internet access for destination VPC
resource "google_compute_router" "destination_vpc_nat" {
  project = var.project_id
  region  = "europe-west1"
  name    = "${google_compute_network.destination_vpc.name}-nat"
  network = google_compute_network.destination_vpc.name
}

resource "google_compute_router_nat" "destination_vpc_nat_config" {
  project                            = var.project_id
  region                             = "europe-west1"
  router                             = google_compute_router.destination_vpc_nat.name
  name                               = "${google_compute_network.destination_vpc.name}-nat-euw1"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}