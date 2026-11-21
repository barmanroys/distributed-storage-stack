#!/usr/bin/env bash

minikube start
kubectl apply --filename rustfs/
kubectl -n object-storage port-forward svc/rustfs 9001:9001
