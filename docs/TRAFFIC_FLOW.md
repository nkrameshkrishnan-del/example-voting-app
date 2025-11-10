# Voting App - Network Traffic Flow Documentation

## Overview
This document explains how network traffic flows through the voting application infrastructure, including external requests, inter-pod communication, database access, and external connectivity patterns.

## Table of Contents
- [VPC Architecture](#vpc-architecture)
- [External Request Flow (User → Application)](#external-request-flow-user--application)
- [Internal Communication (Pod-to-Pod)](#internal-communication-pod-to-pod)
- [Database Access (Pods → RDS)](#database-access-pods--rds)
- [Redis Access (Pods → ElastiCache)](#redis-access-pods--elasticache)
- [Outbound Internet Access](#outbound-internet-access)
- [Security Boundaries](#security-boundaries)

---

## VPC Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           VPC (10.0.0.0/16)                                  │
│                                                                              │
│  ┌────────────────────────────┐     ┌──────────────────────────────┐       │
│  │    Public Subnets          │     │    Private Subnets           │       │
│  │  (10.0.101-103.0/24)       │     │  (10.0.1-3.0/24)             │       │
│  │                            │     │                              │       │
│  │  ┌──────────────────────┐  │     │  ┌────────────────────────┐ │       │
│  │  │  Application LB      │  │     │  │  EKS Node 1            │ │       │
│  │  │  (ALB)               │  │     │  │  ┌──────────┐          │ │       │
│  │  │  Public IP           │◀─┼─────┼─▶│  │ Vote Pod │          │ │       │
│  │  └──────────────────────┘  │     │  │  └──────────┘          │ │       │
│  │                            │     │  │  ┌──────────┐          │ │       │
│  │  ┌──────────────────────┐  │     │  │  │Result Pod│          │ │       │
│  │  │  NAT Gateway         │  │     │  │  └──────────┘          │ │       │
│  │  │  Elastic IP          │◀─┼─────┼──│  ┌──────────┐          │ │       │
│  │  └──────────────────────┘  │     │  │  │Worker Pod│          │ │       │
│  │            │               │     │  │  └──────────┘          │ │       │
│  └────────────┼────────────────┘     │  └────────────────────────┘ │       │
│               │                      │                            │       │
│               │                      │  ┌────────────────────────┐ │       │
│               │                      │  │  RDS PostgreSQL        │ │       │
│               │                      │  │  Primary (Multi-AZ)    │ │       │
│               │                      │  │  Private IP: 10.0.2.Y  │ │       │
│               │                      │  │  Port: 5432 (SSL)      │ │       │
│               │                      │  └────────────────────────┘ │       │
│               │                      │                            │       │
│               │                      │  ┌────────────────────────┐ │       │
│               │                      │  │  ElastiCache Redis     │ │       │
│               │                      │  │  Primary + Replicas    │ │       │
│               │                      │  │  Private IP: 10.0.3.Z  │ │       │
│               │                      │  │  Port: 6379 (TLS)      │ │       │
│               │                      │  └────────────────────────┘ │       │
│               │                      └──────────────────────────────┘       │
│               │                                                             │
└───────────────┼─────────────────────────────────────────────────────────────┘
                ↓
            Internet
        (Docker Hub, PyPI, NuGet, etc.)
```

### Network Segments

| Segment | CIDR | Purpose | Internet Access |
|---------|------|---------|-----------------|
| Public Subnet A | 10.0.101.0/24 | ALB, NAT Gateway | Direct (IGW) |
| Public Subnet B | 10.0.102.0/24 | ALB, NAT Gateway | Direct (IGW) |
| Public Subnet C | 10.0.103.0/24 | ALB, NAT Gateway | Direct (IGW) |
| Private Subnet A | 10.0.1.0/24 | EKS Nodes, RDS, Redis | Via NAT GW |
| Private Subnet B | 10.0.2.0/24 | EKS Nodes, RDS, Redis | Via NAT GW |
| Private Subnet C | 10.0.3.0/24 | EKS Nodes, RDS, Redis | Via NAT GW |

---

## External Request Flow (User → Application)

### End User Voting Request

```
┌──────────┐
│  User's  │
│  Browser │
└─────┬────┘
      │ HTTP/HTTPS
      │ (Public Internet)
      ↓
┌─────────────────────────────────────────────────────┐
│  Route 53 / DNS                                      │
│  voting-app-alb-12345.us-east-1.elb.amazonaws.com   │
└─────┬───────────────────────────────────────────────┘
      │
      ↓
┌──────────────────────────────────────────┐
│  AWS Application Load Balancer (ALB)     │  ← Public Subnets (3 AZs)
│  Listener Rules:                         │
│  - /vote/*  → vote-service:80            │
│  - /result/* → result-service:80         │
│  Health Checks: HTTP:80/                 │
│  Sticky Sessions: Enabled (result)       │
└─────┬────────────────────────────────────┘
      │ Target Group Routing
      │ (Private IPs of NodePorts)
      ↓
┌──────────────────────────────────────────┐
│  Kubernetes Service (NodePort/ClusterIP) │  ← Private Subnets
│  vote-service: 80 → 8080                 │
│  result-service: 80 → 80                 │
└─────┬────────────────────────────────────┘
      │ kube-proxy iptables
      ↓
┌──────────────────────────────────────────┐
│  Pod (vote-XXX or result-XXX)            │
│  Container Port: 80 or 8080              │
│  Application Logic                       │
└──────────────────────────────────────────┘
```

### Request Path Details

1. **User Request**: `https://voting-app-alb-12345.us-east-1.elb.amazonaws.com/vote`
2. **DNS Resolution**: ALB public IP (e.g., 54.x.y.z)
3. **ALB Ingress Rule**: Path `/vote/*` → Target Group `vote-service`
4. **Target Group**: Forwards to NodePort on private EKS nodes (10.0.1.X:30080)
5. **kube-proxy**: Routes to healthy pod on any node via ClusterIP (10.100.x.y:80)
6. **Vote Pod**: Python Flask app handles request, writes to Redis queue

**Key Annotations** (from `k8s-specifications/ingress-simple.yaml`):
```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/healthcheck-path: /
alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true
```

---

## Internal Communication (Pod-to-Pod)

### Vote → Redis (Queue Write)

```
┌─────────────────┐
│   Vote Pod      │  10.0.1.X (Pod IP)
│   Python Flask  │
└────────┬────────┘
         │ Redis protocol (TLS)
         │ LPUSH votes <data>
         ↓
┌─────────────────────────────────────────┐
│  Kubernetes Service: redis-service      │
│  ClusterIP: 10.100.y.y:6379             │
└────────┬────────────────────────────────┘
         │ kube-proxy routing
         ↓
┌─────────────────────────────────────────┐
│  ElastiCache Redis (Private Endpoint)   │  ← Private Subnet B/C
│  master.votingappdev-redis...use1...    │
│  Private IP: 10.0.3.Z:6379              │
│  Transit Encryption: Enabled            │
│  AUTH: Disabled (empty password)        │
└─────────────────────────────────────────┘
```

### Worker → Redis → PostgreSQL (Data Processing)

```
┌──────────────────┐
│  Worker Pod      │  10.0.1.Y (Pod IP)
│  C# .NET         │
└────────┬─────────┘
         │
         ├──[1]──▶ Redis (BRPOP votes) ────────────┐
         │                                         │
         └──[2]──▶ PostgreSQL (INSERT) ────────┐   │
                                            │  │
         ┌─────────────────────────────────────┘   │
         ↓                                         ↓
┌────────────────────────────────┐    ┌────────────────────────────┐
│  RDS PostgreSQL                │    │  ElastiCache Redis         │
│  Private IP: 10.0.2.Y:5432     │    │  Private IP: 10.0.3.Z:6379 │
│  SSL Mode: Require             │    │  TLS: Enabled              │
│  Database: postgres            │    │  Data Structure: List      │
│  Table: votes (a, b, count)    │    └────────────────────────────┘
└────────────────────────────────┘
```

**Worker Logic**:
1. Block-pop vote from Redis queue (`BRPOP votes`)
2. Parse vote data (voter_id, vote)
3. Upsert into PostgreSQL (`UPDATE ... ON CONFLICT`)
4. Repeat in infinite loop

### Result → PostgreSQL (Real-Time Display)

```
┌──────────────────────────┐
│  Result Pod              │  10.0.1.Z (Pod IP)
│  Node.js + Socket.IO     │
└────────┬─────────────────┘
         │ Poll every 1 second
         │ SELECT a, b FROM votes
         ↓
┌─────────────────────────────────────────┐
│  RDS PostgreSQL                         │  ← Private Subnet B
│  voting-app-dev-pg...rds.amazonaws.com  │
│  Private IP: 10.0.2.Y:5432              │
│  SSL Connection Required                │
└────────┬────────────────────────────────┘
         │ Result rows
         ↓
┌──────────────────────────┐
│  Socket.IO Emit          │
│  → Connected browsers    │
│  Path: /result/socket.io │
└──────────────────────────┘
```

**Real-Time Update Flow**:
1. Result pod queries PostgreSQL every 1s
2. Detects vote count changes
3. Emits Socket.IO event to all connected clients
4. Browser updates chart without page refresh

---

## Database Access (Pods → RDS)

### Detailed PostgreSQL Connection Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    VPC (10.0.0.0/16)                                     │
│                                                                          │
│  ┌──────────────────────┐                   ┌────────────────────────┐   │
│  │ Private Subnet A     │                   │ Private Subnet B       │   │
│  │  (10.0.1.0/24)       │                   │  (10.0.2.0/24)         │   │
│  │                      │                   │                        │   │
│  │  ┌────────────────┐  │                   │  ┌──────────────────┐  │   │
│  │  │ EKS Node 1     │  │                   │  │ RDS Primary      │  │   │
│  │  │                │  │  VPC Route Table  │  │ (PostgreSQL 15)  │  │   │
│  │  │ ┌────────────┐ │  │   (Direct L3)     │  │                  │  │   │
│  │  │ │ Worker Pod │ │──┼───────────────────┼─▶│ 10.0.2.42:5432   │  │   │
│  │  │ │ 10.0.1.15  │ │  │   Port: 5432      │  │                  │  │   │
│  │  │ └────────────┘ │  │   Proto: TCP+SSL  │  │ Security Group:  │  │   │
│  │  │                │  │                   │  │ ✓ 10.0.0.0/16    │  │   │
│  │  └────────────────┘  │                   │  │ ✗ 0.0.0.0/0      │  │   │
│  │                      │                   │  └──────────────────┘  │   │
│  └──────────────────────┘                   └────────────────────────┘   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Connection Parameters (from ConfigMap)

```yaml
# k8s-specifications/configmap.yaml
postgres_host: "voting-app-dev-pg.curq228s8eze.us-east-1.rds.amazonaws.com"
postgres_port: "5432"
postgres_user: "postgres"
postgres_db: "postgres"
```

### Security Group Rules (RDS)

**Ingress Rule**:
```hcl
# terraform/main.tf
resource "aws_security_group" "rds" {
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]  # Entire VPC
  }
}
```

**Connection Flow**:
1. Pod resolves `postgres_host` via VPC DNS → private IP (10.0.2.42)
2. Pod initiates TCP SYN to 10.0.2.42:5432
3. VPC routing: Direct route (no NAT) to RDS subnet
4. RDS security group evaluates: Source IP 10.0.1.15 ∈ 10.0.0.0/16? ✓ Allow
5. SSL/TLS handshake enforced by RDS parameter group
6. PostgreSQL authentication (username/password from secret)

### SSL Configuration Required

**Node.js (result service)**:
```javascript
const pool = new Pool({
  connectionString: connectionString,
  ssl: {
    rejectUnauthorized: false  // Trust AWS RDS certificate
  }
});
```

**C# (worker service)**:
```csharp
var connString = $"Host={host};Port={port};Username={user};Password={pass};Database=postgres;SslMode=Require;Trust Server Certificate=true;";
```

**Python (vote service)**: Does not connect to PostgreSQL (only Redis)

---

## Redis Access (Pods → ElastiCache)

### Redis Connection Flow

```
┌───────────────────────────────────────────────────────────────────────────┐
│                    VPC (10.0.0.0/16)                                      │
│                                                                           │
│  ┌──────────────────────┐                   ┌────────────────────────┐    │
│  │ Private Subnet A     │                   │ Private Subnet C       │    │
│  │  (10.0.1.0/24)       │                   │  (10.0.3.0/24)         │    │
│  │                      │                   │                        │    │
│  │  ┌────────────────┐  │                   │  ┌──────────────────┐  │    │
│  │  │ EKS Node 1     │  │                   │  │ ElastiCache      │  │    │
│  │  │                │  │  VPC Route Table  │  │ Redis 7.0        │  │    │
│  │  │ ┌────────────┐ │  │   (Direct L3)     │  │                  │  │    │
│  │  │ │ Vote Pod   │ │──┼───────────────────┼─▶│ 10.0.3.88:6379   │  │    │
│  │  │ │ 10.0.1.20  │ │  │   Port: 6379      │  │                  │  │    │
│  │  │ └────────────┘ │  │   Proto: TLS      │  │ Transit Encrypt: │  │    │
│  │  │                │  │   AUTH: None      │  │ ✓ Enabled        │  │    │
│  │  └────────────────┘  │                   │  │ AUTH Token:      │  │    │
│  │                      │                   │  │ ✗ Disabled       │  │    │
│  └──────────────────────┘                   │  └──────────────────┘  │    │
│                                             └────────────────────────┘    │
└───────────────────────────────────────────────────────────────────────────┘
```

### Connection Parameters (from ConfigMap)

```yaml
# k8s-specifications/configmap.yaml
redis_host: "master.votingappdev-redis.r0rtqe.use1.cache.amazonaws.com"
redis_port: "6379"
redis_ssl: "true"  # Transit encryption enabled
# No redis_password - AUTH token disabled
```

### Security Group Rules (Redis)

```hcl
# terraform/main.tf
resource "aws_security_group" "redis" {
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]  # Entire VPC
  }
}
```

### Application Configuration

**Vote (Python)**:
```python
redis_client = redis.StrictRedis(
    host=redis_host,
    port=6379,
    ssl=True,
    decode_responses=True
)
redis_client.lpush('votes', json.dumps(vote_data))
```

**Worker (C#)**:
```csharp
var config = new ConfigurationOptions {
    EndPoints = { $"{redisHost}:6379" },
    Ssl = true,
    AbortOnConnectFail = false
};
var redis = ConnectionMultiplexer.Connect(config);
```

### Data Flow

1. **Vote Pod**: `LPUSH votes {"voter_id": "abc", "vote": "a"}` → Redis list
2. **Worker Pod**: `BRPOP votes 0` → Blocking pop from list
3. **Result Pod**: No direct Redis access (reads from PostgreSQL)

---

## Outbound Internet Access

### NAT Gateway Route for Private Subnets

```
┌────────────────────────────────────────────────────────────────┐
│  Private Subnet (10.0.1.0/24)                                  │
│                                                                │
│  ┌──────────────────┐                                          │
│  │  EKS Node        │  Needs:                                  │
│  │                  │  - Docker Hub (image pulls)              │
│  │  ┌────────────┐  │  - PyPI (pip install)                    │
│  │  │  Pod       │  │  - NuGet (dotnet restore)                │
│  │  │            │  │  - AWS APIs (ECR, Secrets Manager)       │
│  │  └────────────┘  │                                          │
│  └────────┬─────────┘                                          │
│           │ Destination: 0.0.0.0/0 (default route)             │
│           ↓                                                    │
└───────────┼────────────────────────────────────────────────────┘
            │ Route Table: 0.0.0.0/0 → NAT Gateway
            ↓
┌───────────────────────────────────────────────────────────────┐
│  Public Subnet (10.0.101.0/24)                                │
│                                                               │
│  ┌──────────────────┐                                         │
│  │  NAT Gateway     │  Elastic IP: 54.x.y.z                   │
│  │  (Managed AWS)   │  Source NAT: 10.0.1.X → 54.x.y.z        │
│  └────────┬─────────┘                                         │
└───────────┼───────────────────────────────────────────────────┘
            │ Route Table: 0.0.0.0/0 → Internet Gateway
            ↓
     ┌──────────────┐
     │   Internet   │  (Docker Hub, PyPI, GitHub, etc.)
     └──────────────┘
```

### Example Outbound Flows

**Docker Image Pull**:
```
EKS Node (10.0.1.15) → NAT GW → Internet (hub.docker.com:443)
← Image layers downloaded
```

**Secrets Manager API**:
```
Pod (10.0.1.20) → NAT GW → AWS API Endpoint (secretsmanager.us-east-1.amazonaws.com:443)
← Secret value (RDS password)
```

**NPM Package Install** (during build):
```
CI Runner → ECR Push → EKS Node pulls image (already contains node_modules)
(No runtime npm install - dependencies baked into image)
```

### Cost Optimization Note

Single NAT Gateway shared across all private subnets (`single_nat_gateway = true` in Terraform):
- **Pros**: Lower cost (~$32/month vs ~$96/month for 3 NAT GWs)
- **Cons**: Single point of failure; if NAT GW AZ fails, all private subnets lose internet

**Production Recommendation**: Enable `single_nat_gateway = false` for high availability.

---

## Security Boundaries

### Defense Layers

```
┌───────────────────────────────────────────────────────────────────┐
│  Layer 1: Network Isolation (VPC)                                 │
│  - Private subnets have no direct internet ingress                │
│  - RDS/Redis only accept VPC CIDR (10.0.0.0/16)                   │
│  - ALB is only public-facing component                            │
└───────────────────────────────────────────────────────────────────┘
         ↓
┌───────────────────────────────────────────────────────────────────┐
│  Layer 2: Security Groups (Stateful Firewall)                     │
│  - RDS SG: Allow 5432/tcp from 10.0.0.0/16 only                   │
│  - Redis SG: Allow 6379/tcp from 10.0.0.0/16 only                 │
│  - EKS Node SG: Allow ALB target group health checks              │
└───────────────────────────────────────────────────────────────────┘
         ↓
┌───────────────────────────────────────────────────────────────────┐
│  Layer 3: Encryption in Transit                                   │
│  - RDS: SSL/TLS required (enforced by parameter group)            │
│  - Redis: Transit encryption enabled                              │
│  - ALB: HTTPS listener (optional, currently HTTP for demo)        │
└───────────────────────────────────────────────────────────────────┘
         ↓
┌───────────────────────────────────────────────────────────────────┐
│  Layer 4: IAM & RBAC                                              │
│  - EKS access entries control cluster API access                  │
│  - Node IAM role grants Secrets Manager read permission           │
│  - Kubernetes RBAC (implicit via default service accounts)        │
└───────────────────────────────────────────────────────────────────┘
         ↓
┌───────────────────────────────────────────────────────────────────┐
│  Layer 5: Application Layer                                       │
│  - Vote: Input validation (voter_id, vote choice)                 │
│  - Worker: SQL parameterized queries (prevent injection)          │
│  - Result: Read-only DB access                                    │
└───────────────────────────────────────────────────────────────────┘
```

### Security Group Matrix

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Internet | ALB | 80/443 | HTTP/HTTPS | User requests |
| ALB | EKS Nodes | 30000-32767 | TCP | NodePort health checks |
| EKS Nodes | RDS | 5432 | TCP+SSL | Database queries |
| EKS Nodes | Redis | 6379 | TCP+TLS | Cache/queue operations |
| EKS Nodes | NAT GW | * | * | Outbound internet |
| RDS | EKS Nodes | Ephemeral | TCP | Return traffic (stateful) |
| Redis | EKS Nodes | Ephemeral | TCP | Return traffic (stateful) |

### Attack Surface Analysis

**Exposed**:
- ALB public IP (internet-facing)
- EKS API endpoint (public, IAM-authenticated)

**Protected**:
- EKS worker nodes (private IPs only)
- RDS endpoint (private, VPC-only)
- Redis endpoint (private, VPC-only)

**Mitigation Measures**:
- ALB rate limiting (optional, via AWS WAF)
- EKS API access restricted via IAM policies
- No SSH access to nodes (use `kubectl exec` or Systems Manager)
- Secrets stored in AWS Secrets Manager (not ConfigMaps)
- Read-only database user for result service (recommended enhancement)

---

## Troubleshooting Network Issues

### Common Scenarios

**1. Pod cannot reach RDS**
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxx

# Verify pod can resolve hostname
kubectl exec -it worker-xxx -n voting-app -- nslookup voting-app-dev-pg.xxx.rds.amazonaws.com

# Test connectivity (should timeout if SG blocks)
kubectl exec -it worker-xxx -n voting-app -- nc -zv 10.0.2.42 5432
```

**2. ALB health checks failing**
```bash
# Check target group health
aws elbv2 describe-target-health --target-group-arn arn:aws:...

# Verify service endpoints
kubectl get endpoints -n voting-app

# Test from within cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://vote-service.voting-app.svc.cluster.local/
```

**3. Outbound internet blocked**
```bash
# Check NAT Gateway status
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=vpc-xxxxx"

# Verify route table
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-xxxxx"

# Test from pod
kubectl exec -it vote-xxx -n voting-app -- curl -I https://pypi.org
```

**4. Inter-pod communication fails**
```bash
# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Verify service discovery
kubectl exec -it vote-xxx -n voting-app -- nslookup redis-service.voting-app.svc.cluster.local

# Check network policies (if any)
kubectl get networkpolicies -n voting-app
```

---

## Performance Considerations

### Latency Budget

```
User Request → Application Response
├─ ALB routing: ~5-10ms
├─ Pod scheduling (kube-proxy): ~2-5ms
├─ Application processing: ~10-50ms
│  ├─ Vote: Redis write (< 5ms)
│  ├─ Worker: Redis read + PG write (~10-20ms)
│  └─ Result: PG query (~5-15ms)
└─ Return path (reverse): ~5-10ms
Total: ~30-100ms (target < 200ms)
```

### Optimization Opportunities

1. **Redis Connection Pooling**: Reuse connections (already implemented in apps)
2. **RDS Read Replicas**: Offload result queries to replica (not currently deployed)
3. **ALB Target Type**: Using `ip` mode for direct pod routing (avoids NodePort hop)
4. **Sticky Sessions**: Enabled for result service (WebSocket requirement)
5. **VPC Peering**: If integrating with other VPCs, use peering instead of NAT

### Monitoring Metrics

**CloudWatch Metrics to Track**:
- ALB: `TargetResponseTime`, `RequestCount`, `UnHealthyHostCount`
- RDS: `DatabaseConnections`, `ReadLatency`, `WriteLatency`
- ElastiCache: `NetworkBytesIn/Out`, `CurrConnections`, `EngineCPUUtilization`
- NAT Gateway: `BytesOutToDestination`, `PacketsDropCount`

**Kubernetes Metrics**:
```bash
kubectl top nodes
kubectl top pods -n voting-app
kubectl get hpa -n voting-app  # If autoscaling enabled
```

---

## Reference Diagrams

### Complete Request Flow (Vote Submission)

```
     User Browser
          │
          │ POST /vote
          ↓
     ALB (Public)
          │
          │ Target Group: vote-service
          ↓
  vote-service (ClusterIP)
          │
          │ Port 80 → 8080
          ↓
     Vote Pod (Flask)
          │
          ├─────→ Redis (LPUSH)
          │       │
          │       └─────→ ElastiCache
          │                   │
          │                   ↓
          │              Worker Pod (polling)
          │                   │
          │                   ├─→ Redis (BRPOP)
          │                   └─→ PostgreSQL (INSERT/UPDATE)
          │                           │
          │                           ↓
          │                      RDS Instance
          │                           │
          ↓                           │
     HTTP 200 OK                      │
          │                           │
          └───────────────────────────┘
                                      │
                                      ↓
                               Result Pod (polling DB)
                                      │
                                      └─→ Socket.IO emit
                                            │
                                            ↓
                                      User Browsers
                                    (real-time update)
```

---

## Additional Resources

- [AWS VPC Documentation](https://docs.aws.amazon.com/vpc/latest/userguide/)
- [EKS Networking Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/networking.html)
- [ALB Ingress Controller Guide](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [RDS Security Best Practices](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.Security.html)

---

**Last Updated**: November 2025  
**Infrastructure Version**: Terraform 1.6.0, EKS 1.32, RDS PostgreSQL 15, Redis 7.0
