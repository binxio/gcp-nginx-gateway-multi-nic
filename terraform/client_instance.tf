resource "google_service_account" "client" {
  project    = var.project_id
  account_id = "client"
}

resource "google_project_iam_member" "client_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.client.email}"
}

resource "google_project_iam_member" "client_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.client.email}"
}

resource "google_compute_instance" "client" {
  project = var.project_id
  zone    = "europe-west1-b"
  name    = "client"

  machine_type = "e2-medium"

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
      size  = 20
      type  = "pd-ssd"
    }
  }

  tags = ["allow-iap-access"]

  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.source_vpc_clients.self_link
  }

  service_account {
    email  = google_service_account.client.email
    scopes = ["cloud-platform"]
  }
}
