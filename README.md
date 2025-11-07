# Example Voting App

A simple distributed application running across multiple Docker containers.

## Quick Links

- [Local Development](#getting-started) - Run locally with Docker Compose
- [Kubernetes Deployment](#run-the-app-in-kubernetes) - Deploy to any Kubernetes cluster
- **[AWS EKS with CI/CD](docs/CI_CD_QUICKSTART.md)** - Complete CI/CD pipeline for AWS
- **[AWS Infrastructure Setup](docs/AWS_SETUP.md)** - Detailed AWS configuration guide

## Getting started

Download [Docker Desktop](https://www.docker.com/products/docker-desktop) for Mac or Windows. [Docker Compose](https://docs.docker.com/compose) will be automatically installed. On Linux, make sure you have the latest version of [Compose](https://docs.docker.com/compose/install/).

This solution uses Python, Node.js, .NET, with Redis for messaging and Postgres for storage.

Run in this directory to build and run the app:

```shell
docker compose up
```

The `vote` app will be running at [http://localhost:8080](http://localhost:8080), and the `results` will be at [http://localhost:8081](http://localhost:8081).

Alternately, if you want to run it on a [Docker Swarm](https://docs.docker.com/engine/swarm/), first make sure you have a swarm. If you don't, run:

```shell
docker swarm init
```

Once you have your swarm, in this directory run:

```shell
docker stack deploy --compose-file docker-stack.yml vote
```

## Run the app in Kubernetes

The folder k8s-specifications contains the YAML specifications of the Voting App's services.

### Local Kubernetes (minikube, Docker Desktop)

Run the following command to create the deployments and services. Note it will create these resources in your current namespace (`default` if you haven't changed it.)

```shell
kubectl create -f k8s-specifications/
```

The `vote` web app is then available on port 31000 on each host of the cluster, the `result` web app is available on port 31001.

To remove them, run:

```shell
kubectl delete -f k8s-specifications/
```

### AWS EKS with CI/CD Pipeline

This repository includes a complete CI/CD pipeline for deploying to Amazon EKS using GitHub Actions.

**Features:**
- ✅ Automated Docker image builds and push to Amazon ECR
- ✅ Automated deployment to EKS cluster
- ✅ Support for AWS ElastiCache (Redis) and RDS (PostgreSQL)
- ✅ Secure authentication with OpenID Connect (OIDC)
- ✅ Multiple environment support
- ✅ Rolling updates with health checks

**Quick Start:**

1. **Set up AWS infrastructure** - Follow the [AWS Setup Guide](docs/AWS_SETUP.md)
2. **Configure GitHub Secrets** - Add AWS credentials to your repository
3. **Push to main branch** - Automatically triggers CI/CD pipeline

For detailed instructions, see:
- **[CI/CD Quick Start Guide](docs/CI_CD_QUICKSTART.md)** - Get up and running quickly
- **[AWS Setup Guide](docs/AWS_SETUP.md)** - Complete infrastructure setup
- **[Workflows Documentation](.github/workflows/README.md)** - Workflow details and customization

**GitHub Actions Workflows:**
- `ci-build-push.yml` - Builds and pushes Docker images to ECR
- `cd-deploy-eks.yml` - Deploys application to EKS cluster

## Architecture

![Architecture diagram](architecture.excalidraw.png)

* A front-end web app in [Python](/vote) which lets you vote between two options
* A [Redis](https://hub.docker.com/_/redis/) which collects new votes
* A [.NET](/worker/) worker which consumes votes and stores them in…
* A [Postgres](https://hub.docker.com/_/postgres/) database backed by a Docker volume
* A [Node.js](/result) web app which shows the results of the voting in real time

## Notes

The voting application only accepts one vote per client browser. It does not register additional votes if a vote has already been submitted from a client.

This isn't an example of a properly architected perfectly designed distributed app... it's just a simple
example of the various types of pieces and languages you might see (queues, persistent data, etc), and how to
deal with them in Docker at a basic level.
