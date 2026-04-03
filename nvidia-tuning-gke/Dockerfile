# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Extends the tuning package with baked-in H100/GB200 configs for GKE.
# Config step: prepare_nvidia_configs.sh (populate configmaps from profile)
#              then update_settings.sh (base tuning apply).

ARG TUNING_VERSION=1.1.4
FROM ghcr.io/nvidia/skyhook-packages/tuning:${TUNING_VERSION}

COPY profiles/ /skyhook-package/profiles/
COPY skyhook_dir/prepare_nvidia_configs.sh /skyhook-package/skyhook_dir/
COPY skyhook_dir/prepare_nvidia_configs_check.sh /skyhook-package/skyhook_dir/
COPY config.json /skyhook-package/

RUN chmod +x /skyhook-package/skyhook_dir/prepare_nvidia_configs.sh \
             /skyhook-package/skyhook_dir/prepare_nvidia_configs_check.sh \
             /skyhook-package/skyhook_dir/*.sh
