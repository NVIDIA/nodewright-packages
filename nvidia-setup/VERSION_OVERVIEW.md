# 0.1.x

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI |
|---------|-------------|---------------------|-------------|--------|-------|-----|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  N  |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  N  |

# 0.2.x

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI |
|---------|-------------|---------------------|-------------|--------|-------|-----|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |

# 0.4.x

EKS (unchanged):

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI |
|---------|-------------|---------------------|-------------|--------|-------|-----|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |

OKE (OCI). NV-specific layer only; the base OKE worker bootstrap (oke-init, kubelet,
cri-o, VNIC config) stays in the OKE image. EFA/OFI are intentionally absent (AWS-only).

| service | accelerator | kernel                  | doca/ofed | oci-hpc pkgs | rdma net | lustre | chrony (OCI NTP) | memlock |
|---------|-------------|-------------------------|-----------|--------------|----------|--------|------------------|---------|
| oke     | h100        | 6.8.0-1041-oracle       | 3.3.0     |  Y           |  Y       |  Y     |  Y               |  Y      |
| oke     | gb200       | linux-nvidia-64k (meta) | 3.3.0     |  Y           |  Y       |  Y     |  Y               |  Y      |