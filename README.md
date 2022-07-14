# app-cat-service-prototype

Application catalog service prototype (PostgreSQL)

**WIP** This was copied from the Redis prototype, so there may still be references.

## Requirements

* `kubectl`
* `helm` v3
* `go`
* `docker`
* `kuttl`
* `make`

## Getting started

Short version:

`make provision`

This will
1. Install a local Kubernetes cluster with kubernetes-in-docker (`kind`)
2. Install Crossplane Helm chart
3. Install helm and Kubernetes provider for Crossplane
4. Install Secrets Generator Helm chart (for providing random passwords)
5. Install a CompositeResourceDefinition for the prototype service
6. Install a Composition for the prototype service
7. Deploy a service instance of the prototype
8. Verify that the service is up and usable
9. Provision an S3 bucket using Minio
10. Setup backups using Stackgres' built in backup
11. Setup monitoring via Prometheus Operator

The prototype service is a single instance PostgreSQL server

To uninstall, either run
- `make deprovision` to just uninstall the service instance.
- `make clean` to completely remove the cluster and all artifacts.

## How it works

For a full overview, see the official Crossplane docs at https://crossplane.io.

Terminology overview:

- `CompositeResourceDefinition` or just `Composite` and `XRD`: This basically defines how the user-consumable spec for a service instance should look like
- `Composite`: This is the manifest that contains all the artifacts that are being deployed when a service instance is requested.
- `XPostgreSQLInstance`: In this prototype, this is the cluster-scoped service instance.
- `PostgreSQLnstance`: In this prototype, this is the namespace-scoped reference to a cluster-scoped `XPostgreSQLInstance`. This basically solves some RBAC problems in multi-tenant clusters. Also, generally called a `claim`.

So when users request a service instance, they create a resource of kind `PostgreSQLInstance`, which generates a `XPostgreSQLInstance`, which references a `Composite`, defined by `CompositeResourceDefinition`.

### Custom spec

In order to support more input parameters in the service instance, we have to define the OpenAPI schema in the `CompositeResourceDefinition` and basically define each property and their types, optionally some validation and other metadata.

See `crossplane/composite.yaml` for the definition of the spec and `service/prototype-instance.yaml` for a usage example.

## Future Design Considerations

### Scaling resources

The Stackgres operator handles the memory and CPU limitations for a cluster by using profiles. By assigning each instance its own profile, we're able to provide complete customization for the size. Currently, only the memory can be changed.

Also, the Stackgres operator won't apply scaling changes immediately, for it to be applied a cluster restart has to be triggered (via an ops CR). It's to be defined how we want to handle this.

Two options come to mind:
* We trigger the restarts ourselves by applying the Ops CR with the restart instruction
* We leave it to the customer and have a separate XR to trigger the restart, so the customer can do the restart it at their convenience.

### Self-service of major versions

In the past with a similar project we've updated every instance in a certain time window, and it felt it was "forced from top".
It was very difficult handling updates which require manual upgrades (e.g. Database versions).

Instead, we should aim for a design that allows self-service for users.
They should choose which Version of a service they want and be able to do major version upgrades on their own.

### Supporting multiple major versions

We're providing the same version compatibility as the Stackgres operator provides.

### Deploying additional resources

Crossplane itself is not intended to deploy arbitrary namespaced K8s objects. See [here](https://github.com/crossplane/crossplane/issues/1730) for more information about this topic. To combat this there's the [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) which has a nice feature set.
