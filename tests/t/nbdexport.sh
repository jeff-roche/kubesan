# SPDX-License-Identifier: Apache-2.0

# This test does not use ksan-supported-modes because it directly tests the
# NbdExport CRD without using Volumes or StorageClass at all.

ksan-stage "Creating NbdExport..."

# Manually create an NbdExport CR. Most users will never do this directly,
# but instead rely on KubeSAN to do it automatically based on CSI actions.
kubectl create -f - <<EOF
apiVersion: kubesan.gitlab.io/v1alpha1
kind: NbdExport
metadata:
  name: export
  namespace: kubesan-system
spec:
  export: export
  # The CRD needs a block device in /dev. Cheat and reuse the second VG
  # that this test is otherwise not using; however, this is unsafe to
  # do in a production environment.
  path: "/dev/kubesan-drive-1"
  host: $(__ksan-get-node-name 0)
EOF

# Wait for Status.Conditions["Available"]
ksan-poll 1 30 "kubectl get --namespace kubesan-system -o=jsonpath='{.status.conditions[*]['\''type'\'','\''status'\'']}' nbdexport export | grep --quiet 'Available True'"

ksan-stage "Adding client..."
kubectl patch --namespace kubesan-system nbdexport export --type merge -p "
spec:
  clients:
    - $(__ksan-get-node-name 1)
"
# Run a pod with two containers: one to keep the pod alive indefinitely
# (useful for debugging), the other that checks the NBD connection via
# the accompanying test script
kubectl create -f - <<EOF
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-pod
    spec:
      nodeName: $(__ksan-get-node-name 1)
      terminationGracePeriodSeconds: 0
      restartPolicy: Never
      containers:
        - name: test
          image: $TEST_IMAGE
          command:
            - ./nbdexport-helper.sh
            - "$(kubectl -n kubesan-system get nbdexports export -o jsonpath={.status.uri})"
            - /dev/kubesan-drive-1
          volumeMounts:
            - name: dev
              mountPath: /dev
          securityContext:
            privileged: true
        - name: sleep
          image: $TEST_IMAGE
          command:
            - sleep
            - infinity
      volumes:
        - name: dev
          hostPath:
            path: /dev
            type: Directory
EOF

jsonpath='{.status.containerStatuses[?(@.name=="test")].state.terminated.exitCode}'
ksan-poll 1 60 "[[ \"\$( kubectl get pod test-pod -o jsonpath=\"\${jsonpath}\" )\" = 0 ]]"

ksan-stage "Deleting export..."
kubectl delete pod test-pod --timeout=30s
kubectl delete --namespace kubesan-system --wait=false nbdexport export
ksan-poll 1 30 "kubectl get --namespace kubesan-system -o=jsonpath='{.status.conditions[*]['\''type'\'','\''status'\'']}' nbdexport export | grep --quiet 'Available False'"

ksan-stage "Dropping client..."
kubectl patch --namespace kubesan-system nbdexport export --type merge -p "
spec:
  clients: []
"
ksan-poll 1 30 "[[ -z \"\$(kubectl get --no-headers --namespace kubesan-system nbdexport 2>/dev/null)\" ]]"

ksan-stage "Cleaning up..."