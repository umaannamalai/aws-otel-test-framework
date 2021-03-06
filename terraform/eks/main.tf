# ------------------------------------------------------------------------
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
# -------------------------------------------------------------------------

# creating a eks cluster takes around 10 minutes typically.
# so in the eks/k8s test, we need tester to provide the cluster instead of creating it in terraform
# so that we can shorten the execution time

module "common" {
  source = "../common"

  aoc_image_repo = var.aoc_image_repo
  aoc_version = var.aoc_version
}

module "basic_components" {
  source = "../basic_components"

  region = var.region

  testcase = var.testcase

  testing_id = module.common.testing_id

  mocked_endpoint = "localhost/put-data"

  sample_app = var.sample_app
}

locals {
  eks_pod_config_path = fileexists("${var.testcase}/eks_pod_config.tpl") ? "${var.testcase}/eks_pod_config.tpl" : module.common.default_eks_pod_config_path
  sample_app_image = var.sample_app_image != "" ? var.sample_app_image : module.basic_components.sample_app_image
  mocked_server_image = var.mocked_server_image != "" ? var.mocked_server_image : module.basic_components.mocked_server_image
}

# region
provider "aws" {
  region  = var.region
}

# get eks cluster by name
data "aws_eks_cluster" "testing_cluster" {
  name = var.eks_cluster_name
}
data "aws_eks_cluster_auth" "testing_cluster" {
  name = var.eks_cluster_name
}

# set up kubectl
provider "kubernetes" {
  host = data.aws_eks_cluster.testing_cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.testing_cluster.certificate_authority[0].data)
  token = data.aws_eks_cluster_auth.testing_cluster.token
  load_config_file = false
  version = "~> 1.13"
}

# create a unique namespace for each run
resource "kubernetes_namespace" "aoc_ns" {
  metadata {
    name = "aoc-ns-${module.common.testing_id}"
  }
}
resource "kubernetes_config_map" "aoc_config_map" {
  metadata {
    name = "otel-config"
    namespace = kubernetes_namespace.aoc_ns.metadata[0].name
  }

  data = {
    "aoc-config.yml" = module.basic_components.otconfig_content
  }
}

# load eks pod config
data "template_file" "eksconfig" {
  template = file(local.eks_pod_config_path)

  vars = {
    data_emitter_image = local.sample_app_image
    testing_id = module.common.testing_id
  }
}

# load the faked cert for mocked server
resource "kubernetes_config_map" "mocked_server_cert" {
  metadata {
    name = "mocked-server-cert"
    namespace = kubernetes_namespace.aoc_ns.metadata[0].name
  }

  data = {
    "ca-bundle.crt" = module.basic_components.mocked_server_cert_content
  }
}

locals {
  eks_pod_config = yamldecode(data.template_file.eksconfig.rendered)["sample_app"]
}

# deploy aoc and sample app
resource "kubernetes_deployment" "aoc_deployment" {
  metadata {
    name = "aoc"
    namespace = kubernetes_namespace.aoc_ns.metadata[0].name
    labels = {
      app = "aoc"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "aoc"
      }
    }

    template {
      metadata {
        labels = {
          app = "aoc"
        }
      }


      spec {
        volume {
          name = "otel-config"
          config_map {
            name = kubernetes_config_map.aoc_config_map.metadata[0].name
          }
        }

        volume {
          name = "mocked-server-cert"
          config_map {
            name = kubernetes_config_map.mocked_server_cert.metadata[0].name
          }
        }

        container {
          name = "mocked-server"
          image = local.mocked_server_image

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds = 5
          }
        }

        # aoc
        container {
          name = "aoc"
          image = module.common.aoc_image
          image_pull_policy = "Always"
          args = ["--config=/aoc/aoc-config.yml"]

          resources {
            requests {
              cpu = "0.2"
              memory = "256Mi"
            }
          }

          volume_mount {
            mount_path = "/aoc"
            name = "otel-config"
          }

          volume_mount {
            mount_path = "/etc/pki/tls/certs"
            name = "mocked-server-cert"
          }
        }

        # sample app
        container {
          name = "sample-app"
          image= local.eks_pod_config["image"]
          image_pull_policy = "Always"
          command = length(local.eks_pod_config["command"]) != 0 ? local.eks_pod_config["command"] : null
          args = length(local.eks_pod_config["args"]) != 0 ? local.eks_pod_config["args"] : null


          env {
            name = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "127.0.0.1:55680"
          }

          env {
            name = "AWS_XRAY_DAEMON_ADDRESS"
            value = "127.0.0.1:${module.common.udp_port}"
          }

          env {
            name = "AWS_REGION"
            value = var.region
          }

          env {
            name = "INSTANCE_ID"
            value = module.common.testing_id
          }

          env {
            name = "OTEL_RESOURCE_ATTRIBUTES"
            value = "service.namespace=${module.common.otel_service_namespace},service.name=${module.common.otel_service_name}"
          }

          env {
            name = "LISTEN_ADDRESS"
            value = "${module.common.sample_app_listen_address_ip}:${module.common.sample_app_listen_address_port}"
          }

          resources {
            requests {
              cpu = "0.2"
              memory = "256Mi"
            }

          }

          readiness_probe {
            http_get {
              path = "/"
              port = module.common.sample_app_listen_address_port
            }
            initial_delay_seconds = 10
            period_seconds = 5
          }
        }
      }
    }
  }
}

# create service upon the sample app
resource "kubernetes_service" "sample_app_service" {
  metadata {
    name = "aoc"
    namespace = kubernetes_namespace.aoc_ns.metadata[0].name
  }
  spec {
    selector = {
      app = kubernetes_deployment.aoc_deployment.metadata[0].labels.app
    }

    type = "LoadBalancer"

    port {
      port = module.common.sample_app_lb_port
      target_port = module.common.sample_app_listen_address_port
    }
  }
}

# create service upon the mocked server
resource "kubernetes_service" "mocked_server_service" {
  metadata {
    name = "mocked-server"
    namespace = kubernetes_namespace.aoc_ns.metadata[0].name
  }
  spec {
    selector = {
      app = kubernetes_deployment.aoc_deployment.metadata[0].labels.app
    }

    type = "LoadBalancer"

    port {
      port = 80
      target_port = 8080
    }
  }
}

##########################################
# Validation
##########################################
module "validator" {
  source = "../validation"

  validation_config = var.validation_config
  region = var.region
  testing_id = module.common.testing_id
  metric_namespace = "${module.common.otel_service_namespace}/${module.common.otel_service_name}"
  sample_app_endpoint = "http://${kubernetes_service.sample_app_service.load_balancer_ingress.0.hostname}:${module.common.sample_app_lb_port}"
  mocked_server_validating_url = "http://${kubernetes_service.mocked_server_service.load_balancer_ingress.0.hostname}/check-data"

  aws_access_key_id = var.aws_access_key_id
  aws_secret_access_key = var.aws_secret_access_key

  depends_on = [kubernetes_service.mocked_server_service]
}
