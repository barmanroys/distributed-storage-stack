#!/usr/bin/env bash

minikube start
kubectl apply --filename rustfs/ # Object storage layer for JuiceFS
kubectl apply --filename juice/database.yaml # Metadata service for JuiceFS
kubectl --namespace object-storage port-forward svc/rustfs 9001:9001 # Expose the RustFS GUI console on local port
kubectl --namespace object-storage port-forward svc/postgres 5432:5432 # Expose the PGSQL on local port
# Create bucket via the GUI console, name it as juice-fs-bucket
# Then install the juicefs CSI driver using the standard helm chart
helm repo add juicefs https://juicedata.github.io/charts/
helm repo update
helm upgrade --install juicefs-csi-driver juicefs/juicefs-csi-driver --namespace kube-system --create-namespace
# Both object storage and database services are in the same namespace. The connection pattern follows the documentation
# https://docs.rustfs.com/en/developer/integration/others/juicefs
kubectl apply --filename juice/juicefs-secret.yaml
kubectl apply --filename juice/format-job.yaml
# If the format is successful (you can check the log from K8S dashboard)
# The PGSQL public schema should have several tables created
# The RustFS bucket should have a dummy text file (containing a UUID)
# Architecture documentation at https://juicefs.com/docs/csi/introduction/
# For the next stage, make sure you are using normal amd64 image, not arm. AMD images are more common and saves some special configuration. Look at the output
# of the command
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.architecture}{"\n"}{end}' # Should echo amd64
# Assuming the above shows amd64 image (anything else is outside the scope of this project)
helm upgrade --install juicefs-csi-driver juicefs/juicefs-csi-driver --namespace kube-system --create-namespace
# Wait for a minute or so after running the above, and make sure the csi driver is indeed attached by running the following
kubectl get csidrivers # Should show csi.juicefes.com
