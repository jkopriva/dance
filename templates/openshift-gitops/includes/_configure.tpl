{{ define "rhtap.gitops.configure" }}
- name: configure-gitops
  image: "quay.io/codeready-toolchain/oc-client-base:latest"
  command:
    - /bin/sh
    - -c
    - |
      set -o errexit
      set -o nounset
      set -o pipefail

      echo -n "* Installing 'argocd' CLI: "
      curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
      chmod 555 argocd
      ./argocd version --client | head -1 | cut -d' ' -f2

      CRD="argocds"
      echo -n "* Waiting for '$CRD' CRD: "
      while [ $(kubectl api-resources | grep -c "^$CRD ") = "0" ] ; do
        echo -n "."
        sleep 3
      done
      echo "OK"

      echo -n "* Waiting for gitops operator deployment: "
      until kubectl get argocd openshift-gitops -n openshift-gitops --ignore-not-found >/dev/null; do
        echo -n "."
        sleep 3
      done
      echo "OK"

      #
      # All actions must be idempotent
      #
      CHART="{{ .Chart.Name }}"
      ARGOCD_NAMESPACE="{{ index .Values "openshift-gitops" "argocd-namespace" | default ( print .Release.Namespace "-argocd" ) }}"
      echo -n "* ArgoCD resource: "
      until kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; do
        echo -n "."
        sleep 3
      done
      cat << EOF | kubectl apply -n "$ARGOCD_NAMESPACE" -f - >/dev/null
      {{ include "rhtap.include.argocd" . | indent 8 }}
      EOF
      echo "OK"

      echo -n "* ArgoCD dashboard: "
      test_cmd="kubectl get route -n "$ARGOCD_NAMESPACE" "$CHART-argocd-server" --ignore-not-found -o jsonpath={.spec.host}"
      ARGOCD_HOSTNAME="$(${test_cmd})"
      until curl --fail --insecure --output /dev/null --silent "https://$ARGOCD_HOSTNAME"; do
        echo -n "."
        sleep 2
        ARGOCD_HOSTNAME="$(${test_cmd})"
      done
      echo "OK"

      echo -n " * ArgoCD admin user: "
      if [ "$(kubectl get argocd -n "$ARGOCD_NAMESPACE" "$CHART-argocd" -o jsonpath='{.spec.extraConfig.admin\.enabled}')" = "false" ]; then
        echo "disabled"
        echo -n "* ArgoCD 'admin-$CHART' token: "
        if kubectl get secret "$CHART"-argocd-secret >/dev/null; then
          echo "already generated"
        else
          echo "not available"
          echo "[ERROR] Missing ArgoCD token cannot be created"
          exit 1
        fi
      else
        echo "enabled"
        echo -n "* ArgoCD Login: "
        ARGOCD_PASSWORD="$(kubectl get secret -n "$ARGOCD_NAMESPACE" "$CHART-argocd-cluster" -o jsonpath="{.data.admin\.password}" | base64 --decode)"
        ./argocd login "$ARGOCD_HOSTNAME" --grpc-web --insecure --username admin --password "$ARGOCD_PASSWORD" >/dev/null
        echo "OK"
        # echo "argocd login '$ARGOCD_HOSTNAME' --grpc-web --insecure --username admin --password '$ARGOCD_PASSWORD'"

        echo -n "* ArgoCD 'admin-$CHART' token: "
        if [ "$(kubectl get secret "$CHART-argocd-secret" -o name --ignore-not-found | wc -l)" = "0" ]; then
          echo -n "."
          ARGOCD_API_TOKEN="$(./argocd account generate-token --account "admin-$CHART")"
          echo -n "."
          ARGOCD_USER_PASSWORD=$(openssl rand --base64 20 | tr -d '=')
          ./argocd account update-password \
            --account "admin-$CHART" \
            --current-password "$ARGOCD_PASSWORD" \
            --new-password "$ARGOCD_USER_PASSWORD" > /dev/null
          echo -n "."
          kubectl create secret generic "$CHART-argocd-secret" \
            --from-literal="api-token=$ARGOCD_API_TOKEN" \
            --from-literal="hostname=$ARGOCD_HOSTNAME" \
            --from-literal="password=$ARGOCD_USER_PASSWORD" \
            --from-literal="user=admin-$CHART" \
            > /dev/null
        fi
        echo "OK"

        echo -n "* Disable ArgoCD admin user: "
        kubectl patch argocd -n "$ARGOCD_NAMESPACE" "$CHART-argocd" --type 'merge' --patch '{{ include "rhtap.argocd.user_admin" . | indent 8 }}' >/dev/null
        echo "OK"
      fi

      {{ include "rhtap.openshift-pipelines.wait" . | indent 6 }}

      echo -n "* Configuring Tasks: "
      cat << EOF | kubectl apply -f - >/dev/null
      {{ include "rhtap.openshift-gitops.argocd-login-check" . | indent 6 }}
      EOF

      echo
      echo "Configuration successful"
{{ end }}