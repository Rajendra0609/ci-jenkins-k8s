kubectl patch ingress jenkins-ingress -n jenkins \
  --type=merge \
  -p '{
    "metadata": {
      "annotations": {
        "nginx.ingress.kubernetes.io/proxy-buffer-size": "16k",
        "nginx.ingress.kubernetes.io/proxy-read-timeout": "3600",
        "nginx.ingress.kubernetes.io/proxy-send-timeout": "3600"
      }
    }
  }'


  kubectl patch ingress jenkins-ingress -n jenkins \
  --type=merge \
  -p '{
    "metadata": {
      "annotations": {
        "nginx.ingress.kubernetes.io/affinity": "cookie",
        "nginx.ingress.kubernetes.io/session-cookie-name": "SESSIONID",
        "nginx.ingress.kubernetes.io/session-cookie-hash": "sha1"
      }
    }
  }'


