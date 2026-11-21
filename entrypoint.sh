#!/usr/bin/env bash

minikube start
kubectl apply --filename rustfs/ # To apply the rustfs manifests
kubectl apply --filename juice/
kubectl --namespace object-storage port-forward svc/rustfs 9001:9001 # Expose the RustFS GUI console on local port
kubectl --namespace object-storage port-forward svc/postgres 5432:5432 # Expose the PGSQL on local port
# Create bucket via the GUI console, name it as juice-fs-bucket
#
