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

# 0.2.x (0.2.3+)

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | system_node_settings | cloud_init_cfg | Lustre        |
|---------|-------------|---------------------|-------------|--------|-------|-----|----------------------|----------------|---------------|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  Y                   |  Y             |  opt-in       |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  Y                   |  Y             |  opt-in       |