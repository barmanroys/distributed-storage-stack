# JuiceFS on Kubernetes: shared storage, without the hand-waving

A small, hands-on Kubernetes workshop that wires together **RustFS
(S3-compatible object storage)**, **PostgreSQL (JuiceFS metadata)** and
**JuiceFS CSI** --- then proves the result with two Pods sharing the
same filesystem.

Here is the finish line. A writer Pod creates a file
under `/mnt/models`, and a reader Pod can read it, both using standard Posix file interface (not object storage interface). The interesting part 
is the unerlying connection from `date>/mnt/models/date.txt` in a so called _writer_ pod to `cat /mnt/models/date.txt` a so called _reader_ pod. 

> **Scope:** this walkthrough targets a local Minikube environment using
> a Linux PC and `amd64` node. Other architectures and platforms may need different container
> images or additional configuration, and I would welcome your feedback to enhance this tutorial. 

## Target State 

``` mermaid
flowchart TB
    subgraph K8s["Kubernetes / Minikube"]
        subgraph Apps["Application Pods"]
            W["Writer Pod"]
            R["Reader Pod"]
        end
        PVC["PVC: shared JuiceFS volume<br/>mounted at /mnt/models"]
        CSI["JuiceFS CSI driver"]
        W --> PVC
        R --> PVC
        PVC --> CSI
    end

    CSI --> JFS["JuiceFS filesystem"]
    JFS --> PG[("PostgreSQL<br/>filesystem metadata")]
    JFS --> S3[("RustFS bucket<br/>file data / objects")]
```

The responsibilities of different components 

-   **RustFS** stores the file data as objects in an S3-compatible
    bucket (far cheaper and ubiquitous than Posix based storage).
-   **PostgreSQL** stores JuiceFS filesystem metadata.
-   **JuiceFS** presents a filesystem abstraction over those two backends (RustFS+PostgreSQL).
-   **JuiceFS CSI** connects that filesystem to Kubernetes volumes.
-   **The PVC** is what application Pods consume. They don't know about Juice, RustFS or PostgreSQL.

### Motivation: Shared Model Artefacts Across Training and Inference
The motivating scenario is a machine learning model orchestration platform with two kinds of workloads:
- Training Pods consume relevant datasets, train TensorFlow models, and write the resulting model artefacts to shared storage.
- Inference Pods load those trained artefacts and serve predictions to downstream clients.
In a more complete system, the writer and reader in this lab would evolve into those workloads. A training workload might publish a versioned model directory, while an inference workload mounts the same storage and loads the model without requiring a separate file-transfer mechanism between Pods.
``` mermaid
flowchart LR
    D[Training data] --> T[Training Pods<br/>TensorFlow]
    T -->|Publish model artefacts| S[(Shared JuiceFS volume)]
    S -->|Load model artefacts| I[Inference Pods]
    I --> C[Downstream clients]
```
However, the exact application purpose is deliberately not the focus of this PoC. TensorFlow training and inference are the motivating examples, not features being implemented here. The objective is to explore and validate the storage architecture underneath such a workflow: object storage, metadata storage, the JuiceFS filesystem, Kubernetes CSI integration, and shared filesystem access across multiple Pods.

The same architecture could support many other workloads that need to publish files in one Pod and consume them in another. The writer and reader are intentionally minimal so that the storage behaviour can be isolated, understood and verified independently of application-level complexity.

### Why JuiceFS Instead of Using a Kubernetes PVC Directly?

A reasonable question at this point is: **if Kubernetes already provides PersistentVolumeClaims (PVCs), why introduce RustFS, JuiceFS, PostgreSQL and a CSI driver? Why not simply mount a Minikube PVC into the application Pods and call it a day?**

That's a perfectly valid question. In fact, for a simple application running on a single node that needs persistent storage, a regular Minikube PVC may be all you need.

The distinction is that a PVC is an abstraction for requesting storage, not a storage architecture in itself. Its capabilities depend on the underlying storage provisioner and backend.

#### What does a conventional Minikube PVC give you?

A typical Minikube PVC backed by its default storage provisioner gives you persistent storage within the cluster. Depending on the underlying driver and access mode, it may support mounting that storage into application Pods.

But that doesn't automatically give you:

- An S3-compatible object-storage backend.
- A filesystem abstraction that separates metadata from physical data storage.
- A shared filesystem designed to be mounted by multiple Pods, potentially across different Kubernetes nodes.
- A reusable storage layer that can be backed by object storage independently of the application workloads.

#### What does the additional ceremony bring?

The components in this PoC each have a distinct responsibility:

| Component | Responsibility |
|---|---|
| Kubernetes PVC | Application-facing storage abstraction |
| JuiceFS CSI | Integrates JuiceFS volumes with Kubernetes |
| JuiceFS | Provides the shared POSIX filesystem interface |
| PostgreSQL | Persists filesystem metadata |
| RustFS | Stores the actual file data as S3-compatible objects |

The application still consumes a PVC. It doesn't need to know that PostgreSQL and RustFS exist underneath.

## Who is this PoC for?

This PoC is primarily aimed at:
- ML engineers building training and inference workloads on Kubernetes.
- Data engineers interested in object storage, distributed filesystems and storage abstractions.
- Developers curious about how Kubernetes storage integrates with external infrastructure.

### What should you already know?

You'll get the most out of this exercise if you have:

- A working understanding of Kubernetes fundamentals: Pods, Deployments, Services, PersistentVolumes (PVs), PersistentVolumeClaims (PVCs) and CSI drivers.
- Some familiarity with containerised workloads and basic `kubectl` operations.
- An appreciation of why multiple application instances might need to access the same files, and the challenges around shared read/write access. 

You don't need prior experience with JuiceFS, RustFS, Iceberg-style storage architectures or distributed filesystems. Exploring how these components fit together is precisely the point of the exercise. But what you do need, is a lot of curiosity. 


## Repository layout

The commands below assume a layout along these lines:

``` text
.
├── entrypoint.sh
├── rustfs/
│   └── ...                 # RustFS Kubernetes manifests
├── juice/
│   ├── database.yaml       # PostgreSQL manifest
│   ├── juicefs-secret.yaml # JuiceFS connection details
│   ├── format-job.yaml    # One-time JuiceFS format job
│   ├── storageclass.yaml  # JuiceFS-backed StorageClass
│   ├── pvc.yaml            # Shared PVC
│   └── test-pod.yaml       # Writer and reader Pods
└── README.md
```

Your actual filenames and manifest contents are the source of truth. In
particular, make sure the Secret contains the correct PostgreSQL
connection URL and RustFS endpoint, bucket name, and credentials.
**Don't commit real credentials**: use a local, untracked Secret
manifest or a secret-management mechanism appropriate to your
environment.

## Prerequisites

What I used (and likely you will need something similar, minor version changes should not cause any issue)
-   A PC running Ubuntu 26.04 
-   Docker version 29.10.0
-   Minikube version 1.39.0
-   `kubectl` client 1.37.2
-   Helm 4.3.2 
-   A Kubernetes context pointing at the Minikube cluster

Start the cluster:

``` bash
minikube start
kubectl get nodes
```

Check the node architecture:

``` bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.architecture}{"\n"}{end}'
```

This walkthrough assumes the output reports `amd64`. If it reports
something else, stop here and check that the images used by your
manifests and the JuiceFS CSI components support that architecture.

## Step 1 --- Bring up the backends

Apply the RustFS manifests and PostgreSQL manifest:

``` bash
kubectl apply --filename rustfs/
kubectl apply --filename juice/database.yaml
```

The walkthrough expects both services to live in the `object-storage`
namespace, with Services named `rustfs` and `postgres`. Adjust the
commands below if your manifests use different names.

Check that the Pods are ready before moving on:

``` bash
kubectl get pods -n object-storage
kubectl get services -n object-storage
```

Wait for the RustFS and PostgreSQL workloads to become ready. Applying a
manifest only submits the desired resources to Kubernetes; it does not
mean the backing service is already accepting connections.

### Optional: open the management interfaces locally

In separate terminals, try to run the followings for easy to use local interfaces 

``` bash
kubectl -n object-storage port-forward svc/rustfs 9001:9001 # RustFS Web Console 
```

``` bash
kubectl -n object-storage port-forward svc/postgres 5432:5432 # PostgreSQL
```

Use the RustFS console to create a bucket named `juice-fs-bucket`. You can connect a local PostgreSQL client (for example, DataGrip) to `localhost:5432` while the port-forward is running.

## Step 2 --- Install the JuiceFS CSI driver

Add the JuiceFS Helm repository and install the CSI driver:

``` bash
helm repo add juicefs https://juicedata.github.io/charts/
helm repo update

helm upgrade --install juicefs-csi-driver juicefs/juicefs-csi-driver \
  --namespace kube-system --create-namespace
```

Give Kubernetes a little time to start the controller and node
components. Then check:

``` bash
kubectl get pods --namespace kube-system
kubectl get csidrivers
```

You should see the JuiceFS CSI driver registered as `csi.juicefs.com`.

For background on how the driver integrates with Kubernetes, see the
[JuiceFS CSI documentation](https://juicefs.com/docs/csi/introduction/).

## Step 3 --- Configure and format the JuiceFS filesystem

Apply the Secret containing the connection details for PostgreSQL and
RustFS:

``` bash
kubectl apply --filename juice/juicefs-secret.yaml
```

Now run the format Job:

``` bash
kubectl apply --filename juice/format-job.yaml
```

Check its status and logs:

``` bash
kubectl get jobs -n object-storage
kubectl logs -n object-storage job/<format-job-name>
```

Replace `<format-job-name>` with the Job name in `format-job.yaml`.

A successful format should initialise JuiceFS metadata in PostgreSQL and
configure the object-storage backend. Useful signs to inspect are:

-   The format Job completes successfully.
-   JuiceFS metadata tables appear in the PostgreSQL database.
-   The RustFS bucket contains objects created during filesystem
    initialisation.

The exact number and contents of PostgreSQL tables and RustFS objects
are implementation details; don't expect them to look like a normal
directory listing.

> **Important:** formatting is an initialisation step, not a routine
> deployment step. Do not repeatedly run `juicefs format` against an
> existing filesystem, and do not add a force option just to make a Job
> rerun. Reinitialising an existing filesystem can destroy access to its
> data.

## Step 4 --- Create the StorageClass and PVC

Once the CSI driver is registered and the filesystem has been formatted,
apply the StorageClass and claim:

``` bash
kubectl apply --filename juice/storageclass.yaml
kubectl apply --filename juice/pvc.yaml
```

Check that the claim is bound:

``` bash
kubectl get storageclass
kubectl get pvc -n object-storage
kubectl get pv
```

The PVC should reach `Bound`. The test Pods will use this claim to mount
the same JuiceFS filesystem.

## Step 5 --- Deploy the writer and reader

Apply the test Pods:

``` bash
kubectl apply --filename juice/test-pod.yaml
```

Wait until both Pods are running:

``` bash
kubectl get pods -n object-storage -w
```

The manifest should define two Pods that both mount the same PVC at
`/mnt/models` --- one named `juicefs-writer` and the other
`juicefs-reader` in this example.

## Step 6 --- Prove that the filesystem is shared

If you can access the cluster's dashboard, you can easily `exec` into the pods, and navigate to the respective directories for testing. In the absence of a dashboard, try the followings. 

Open a shell in the writer Pod:

``` bash
kubectl exec -it -n object-storage juicefs-writer -- sh
```

Create a file:

``` bash
date > /mnt/models/date.txt
cat /mnt/models/date.txt
```

Now open a shell in the reader Pod:

``` bash
kubectl exec -it -n object-storage juicefs-reader -- sh
```

Read the same file:

``` bash
cat /mnt/models/date.txt
```

If the reader prints the timestamp written by the writer, both Pods are
seeing the same mounted filesystem. That is it. It is deceptively, and annoyingly simple, but shows the capability we need to orchestrate any workload that requires this feature. 

You can also try creating a file from the reader and reading it from the
writer.

## Troubleshooting checkpoints

If something doesn't work, inspect the layer where the failure occurs
rather than repeatedly applying everything:

``` bash
# Workloads and Services
kubectl get pods,services -n object-storage

# PVC and PV state
kubectl get pvc -n object-storage
kubectl get pv

# Why a Pod or claim is stuck
kubectl describe pod -n object-storage <pod-name>
kubectl describe pvc -n object-storage <pvc-name>

# Recent namespace events
kubectl get events -n object-storage --sort-by=.lastTimestamp

# CSI driver registration and Pods
kubectl get csidrivers
kubectl get pods -n kube-system
```

A few useful distinctions:

-   `Pending` PVC: inspect the StorageClass, CSI provisioning events and
    driver health.
-   Pod stuck in `ContainerCreating`: inspect Pod events for volume
    mount or image-pull errors.
-   Format Job failed: inspect its logs, Secret values, PostgreSQL
    connectivity, RustFS endpoint and bucket.
-   Pod is running but a file is missing: confirm both Pods mount the
    same PVC at the intended path.

## What this lab proves --- and what it doesn't

**It proves:**

-   The JuiceFS CSI driver can provision a Kubernetes volume in this
    cluster.
-   Two Pods can mount the same claim.
-   A file written by one Pod is visible to the other.

**It does not yet prove:**

-   Cross-node behaviour: a single-node Minikube cluster only tests
    sharing between Pods on that node.
-   Production-grade resilience, throughput or latency.
-   Every POSIX edge case or behaviour under concurrent writes.

Good next experiments are Pod deletion and recreation (persistence),
simultaneous writes to different files, rename/delete visibility, and
then a multi-node Minikube test.

------------------------------------------------------------------------

## References

-   [JuiceFS CSI
    documentation](https://juicefs.com/docs/csi/introduction/)
-   [RustFS JuiceFS integration
    guide](https://docs.rustfs.com/en/developer/integration/others/juicefs)

If you run into trouble, capture the relevant `kubectl describe` output
and Pod or Job logs. Those usually tell you which layer needs attention.


### Feedback and Ideas

I'm always interested in hearing from engineers who have experience with Kubernetes storage, distributed filesystems, or ML infrastructure.

If you have suggestions, spot something that could be improved, or would like to discuss alternative architectural approaches, feel free to hit my [inbox](mailto:swagatopablo@aol.com).
