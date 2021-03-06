terraform {
  required_version = ">= 0.12.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
    powerdns = {
      source  = "pan-net/powerdns"
      version = ">= 1.3"
    }
    icinga2 = {
      source  = "Icinga/icinga2"
      version = ">= 0.5.0"
    }
  }
}

locals {
  common_labels = merge(var.labels, {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/component"  = "ingress"
  })
}

resource "kubernetes_ingress" "ingress" {
  metadata {
    namespace = var.namespace
    name      = var.object_prefix
    annotations = merge({
      "kubernetes.io/ingress.class" = var.ingress_class },
      var.tls_enabled ? { format("%s/%s", "cert-manager.io", var.cert_issuer_type) = var.cert_issuer_name } : {},
      var.ingress_annotations
    )
    labels = local.common_labels
  }
  wait_for_load_balancer = true
  spec {
    dynamic "rule" {
      for_each = flatten([var.dns_fqdn])
      content {
        host = rule.value
        http {
          path {
            path = "/"
            backend {
              service_name = var.service_name
              service_port = var.service_port
            }
          }
        }
      }
    }
    dynamic "tls" {
      for_each = var.tls_enabled ? [1] : []
      content {
        hosts       = flatten([var.dns_fqdn])
        secret_name = kubernetes_secret.ingress[0].metadata[0].name
      }
    }
  }
}

resource "kubernetes_secret" "ingress" {
  count = var.tls_enabled ? 1 : 0
  metadata {
    namespace = var.namespace
    name      = format("%s-%s", var.object_prefix, "tls")
    labels    = merge(var.labels, local.common_labels)
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations, data]
  }
  provisioner "local-exec" {
    when    = destroy
    command = "sleep 2"
  }
}

resource "powerdns_record" "ingress" {
  for_each = toset(flatten([var.dns_fqdn]))
  zone     = var.dns_zone
  name     = format("%s.", each.value)
  type     = "A"
  ttl      = var.dns_record_ttl
  records  = [kubernetes_ingress.ingress.status.0.load_balancer.0.ingress.0.ip]

  provisioner "local-exec" {
    when    = destroy
    command = "sleep 2"
  }
}

resource "icinga2_host" "host" {
  for_each = var.monitoring_enabled ? length(var.monitoring_host) > 0 ? toset(
  flatten([var.monitoring_host])) : toset(flatten([var.dns_fqdn])) : []
  hostname      = each.value
  address       = kubernetes_ingress.ingress.status.0.load_balancer.0.ingress.0.ip
  check_command = "http"
  vars = merge({
    http_vhost  = each.value
    http_uri    = var.monitoring_uri
    http_ssl    = var.tls_enabled ? true : false
    http_expect = var.monitoring_expect
  }, var.monitoring_vars)
}
