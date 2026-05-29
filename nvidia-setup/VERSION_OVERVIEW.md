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

# 0.3.x

Adds the `bcm` service. `service=bcm`'s sole job is to alias `/usr/src/linux-$(uname -r)` to the Ubuntu `linux-headers-$(uname -r)` tree so consumers reading `/usr/src/linux-$(uname -r)/.config` find it (AICR #1093). For `service=bcm` the apply stage skips the kernel/EFA pipeline and runs only this single step.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  N                |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  N                |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |