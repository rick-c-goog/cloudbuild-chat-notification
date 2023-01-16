/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 
locals {
  chat_storage_bucket = "cloudbuild-chatnotifier"
  cr_chat_notifiy="googlechat-notifier"
  chat_nofity_config_file="chatnotifier.yaml"
  sa_pubsub_invoker="cloud-run-pubsub-invoker"
  pubsub_chat_notify_topic="cloud-builds"

  labels = {
    foo = "bar"
  }

  message_retention_duration = "86600s"
}


data "google_project" "project" {
  project_id = var.project_id
}
/******************************************
1. Project Services Configuration
 *****************************************/
module "activate_service_apis" {
  source                      = "terraform-google-modules/project-factory/google//modules/project_services"
  project_id                  = var.project_id
  enable_apis                 = true

  activate_apis = [
    "orgpolicy.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "containerregistry.googleapis.com",
    "cloudbuild.googleapis.com"
  ]

  disable_services_on_destroy = false
  
}

resource "time_sleep" "sleep_after_activate_service_apis" {
  create_duration = "60s"

  depends_on = [
    module.activate_service_apis
  ]
}
data "google_compute_default_service_account" "default" {
  project = data.google_project.project.project_id
  
}

resource "google_project_iam_member" "storage_access_role" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
  depends_on = [data.google_compute_default_service_account.default]
}

#2. secret manager, secret with webhook data, IAM permission for compute service account
resource "google_secret_manager_secret" "webhook-secret" {
  secret_id = "chat-webhook"

  labels = {
    label = "chat-webhook"
  }

  replication {
    automatic = true
  }
}


resource "google_secret_manager_secret_version" "secret-version-basic" {
  secret = google_secret_manager_secret.webhook-secret.id

  secret_data = var.chat_space_webhook
}


resource "google_secret_manager_secret_iam_binding" "secret-iam-binding" {
  project = var.project_id
  secret_id = google_secret_manager_secret.webhook-secret.secret_id
  role = "roles/secretmanager.secretAccessor"
  members = [
    "serviceAccount:${data.google_compute_default_service_account.default.email}",
  ]
  depends_on = [data.google_compute_default_service_account.default]
}


/******************************************
3. Chat notification config file
 *****************************************/
resource "google_storage_bucket" "chat_storage_bucket" {
    name     = local.chat_storage_bucket
    location = var.region
    uniform_bucket_level_access       = true
    force_destroy                     = true
}

resource "google_storage_bucket_object" "chat-config-file" {
  name   = "chat-nofify-config"
  source = local.chat_nofity_config_file
  bucket = "cloudbuild-chatnotifier"
}

/******************************************
4. Chat notification cloud run service
 *****************************************/


resource "google_cloud_run_service" "chat_notify_service" {
  name     = local.cr_chat_notifiy
  location = var.region

  template {
    spec {
      containers {
        image = "us-east1-docker.pkg.dev/gcb-release/cloud-build-notifiers/googlechat:latest"
        env {
          name  = "CONFIG_PATH"
          value = "gs://${local.chat_storage_bucket}/${local.chat_nofity_config_file}"
        }
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
      }
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "3"
      }
    }
  }

  autogenerate_revision_name = true
  depends_on=[google_storage_bucket.chat_storage_bucket,google_storage_bucket_object.chat-config-file]

}

#5. create pubsub
resource "google_project_iam_binding" "pubsub_binding" {
  project = data.google_project.project.project_id
  role               = "roles/iam.serviceAccountTokenCreator"
  members  =  ["serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"]
  depends_on = [data.google_compute_default_service_account.default]
}

resource "google_service_account" "pubsub_service_account" {
  account_id   = local.sa_pubsub_invoker
  display_name = "Cloud Run Pub/Sub Invoker"
}

#6. Pubsub cloud run service IAM binding
resource "google_cloud_run_service_iam_binding" "pubsub-cr-binding" {
  location = google_cloud_run_service.chat_notify_service.location
  project = google_cloud_run_service.chat_notify_service.project
  service = google_cloud_run_service.chat_notify_service.name
  role = "roles/run.invoker"
  members = [
    "serviceAccount:cloud-run-pubsub-invoker@${var.project_id}.iam.gserviceaccount.com",
  ]
}

#7 pubsub topic
resource "google_pubsub_topic" "chat_notify_topic" {
  name = local.pubsub_chat_notify_topic

  labels = {
    channel = "cr-test"
  }

  #message_retention_duration = "86600s"
}

#8 pubsub push subscription, 
resource "google_pubsub_subscription" "example" {
  name  = "chat-notify-subscription"
  topic = google_pubsub_topic.chat_notify_topic.name

  ack_deadline_seconds = 20

  labels = {
    channel = "cloud build status"
  }

  push_config {
    push_endpoint = google_cloud_run_service.chat_notify_service.status[0].url

    attributes = {
      x-goog-version = "v1"
    }
    oidc_token {
        service_account_email="cloud-run-pubsub-invoker@${var.project_id}.iam.gserviceaccount.com"
    }
  }
}