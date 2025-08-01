#!/usr/bin/env bash
source ${LLMDBENCH_CONTROL_DIR}/env.sh

if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 1 ]]; then

  check_storage_class
  if [[ $? -ne 0 ]]
  then
    announce "❌ Failed to check storage class"
    exit 1
  fi

  check_affinity
  if [[ $? -ne 0 ]]
  then
    announce "❌ Failed to check affinity"
    exit 1
  fi

  extract_environment

  # deploy models
  for model in ${LLMDBENCH_DEPLOY_MODEL_LIST//,/ }; do
    export LLMDBENCH_DEPLOY_CURRENT_MODEL=$(model_attribute $model model)

    # If LLMDBENCH_VLLM_MODELSERVICE_URI is not defined, set it to pvc://
    if [[ -n "$LLMDBENCH_VLLM_MODELSERVICE_URI" ]]; then
      export LLMDBENCH_VLLM_MODELSERVICE_URI="pvc://${LLMDBENCH_VLLM_COMMON_PVC_NAME}/models/$(model_attribute $model model)"
    fi
    llmdbench_execute_cmd "mkdir -p ${LLMDBENCH_CONTROL_WORK_DIR}/setup/helm/${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}/ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}

    cat << EOF > ${LLMDBENCH_CONTROL_WORK_DIR}/setup/helm/${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}/ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}/values.yaml
multinode: false

modelArtifacts:
  uri: $LLMDBENCH_VLLM_MODELSERVICE_URI
  size: $LLMDBENCH_VLLM_COMMON_PVC_MODEL_CACHE_SIZE
  authSecretName: "llm-d-hf-token"
  name: $(model_attribute $model model)

routing:
  modelName: $(model_attribute $model model)
  servicePort: ${LLMDBENCH_VLLM_COMMON_INFERENCE_PORT}
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: infra-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-inference-gateway
  proxy:
    secure: false
  inferenceModel:
    create: false
  inferencePool:
    create: false
    name: gaie-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}
  httpRoute:
    create: $(echo $LLMDBENCH_VLLM_MODELSERVICE_ROUTE | $LLMDBENCH_CONTROL_SCMD -e 's/^0/false/' -e 's/1/true/')

  epp:
    create: false

decode:
  create: $(echo $LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS | $LLMDBENCH_CONTROL_SCMD -e 's/^0/false/' -e 's/[1-9].*/true/')
  replicas: ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS}
  acceleratorTypes:
      labelKey: $(echo $LLMDBENCH_VLLM_COMMON_AFFINITY | cut -d ':' -f 1)
      labelValues:
        - $(echo $LLMDBENCH_VLLM_COMMON_AFFINITY | cut -d ':' -f 2)
  annotations:
      $(add_annotations)
  containers:
  - name: "vllm"
    mountModelVolume: true
    image: "$(get_image ${LLMDBENCH_LLMD_IMAGE_REGISTRY} ${LLMDBENCH_LLMD_IMAGE_REPO} ${LLMDBENCH_LLMD_IMAGE_NAME} ${LLMDBENCH_LLMD_IMAGE_TAG} 0)"
    modelCommand: ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_MODEL_COMMAND}
    $(add_command $LLMDBENCH_VLLM_MODELSERVICE_DECODE_MODEL_COMMAND)
    args:
      $(add_command_line_options ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_ARGS})
    env:
      - name: VLLM_NIXL_SIDE_CHANNEL_HOST
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      - name: HF_HOME
        value: ${LLMDBENCH_VLLM_STANDALONE_PVC_MOUNTPOINT}
      $(add_additional_env_to_yaml $LLMDBENCH_VLLM_COMMON_ENVVARS_TO_YAML)
    resources:
      limits:
        memory: $LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_MEM
        cpu: "$LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_NR"
        $(echo "$LLMDBENCH_VLLM_COMMON_ACCELERATOR_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_DECODE_ACCELERATOR_NR}\"")
        $(echo "$LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_NR}\"" | $LLMDBENCH_CONTROL_SCMD -e 's/^: \"\"//')
      requests:
        memory: $LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_MEM
        cpu: "$LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_NR"
        $(echo "$LLMDBENCH_VLLM_COMMON_ACCELERATOR_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_DECODE_ACCELERATOR_NR}\"")
        $(echo "$LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_NR}\"" | $LLMDBENCH_CONTROL_SCMD -e 's/^: \"\"//')
    startupProbe:
      httpGet:
        path: /health
        port: ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_INFERENCE_PORT}
      failureThreshold: 60
      initialDelaySeconds: ${LLMDBENCH_VLLM_COMMON_INITIAL_DELAY_PROBE}
      periodSeconds: 30
      timeoutSeconds: 5
    livenessProbe:
      tcpSocket:
        port: ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_INFERENCE_PORT}
      failureThreshold: 3
      periodSeconds: 5
    readinessProbe:
      httpGet:
        path: /health
        port: 8200
      failureThreshold: 3
      periodSeconds: 5
    volumeMounts:
    - name: metrics-volume
      mountPath: /.config
    - name: shm
      mountPath: /dev/shm
    - name: torch-compile-cache
      mountPath: /.cache
  volumes:
  - name: metrics-volume
    emptyDir: {}
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: "16Gi"
  - name: torch-compile-cache
    emptyDir: {}

prefill:
  create: $(echo $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS | $LLMDBENCH_CONTROL_SCMD -e 's/^0/false/' -e 's/[1-9].*/true/')
  replicas: ${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS}
  acceleratorTypes:
      labelKey: $(echo $LLMDBENCH_VLLM_COMMON_AFFINITY | cut -d ':' -f 1)
      labelValues:
        - $(echo $LLMDBENCH_VLLM_COMMON_AFFINITY | cut -d ':' -f 2)
  annotations:
      $(add_annotations)
  containers:
  - name: "vllm"
    mountModelVolume: true
    image: "$(get_image ${LLMDBENCH_LLMD_IMAGE_REGISTRY} ${LLMDBENCH_LLMD_IMAGE_REPO} ${LLMDBENCH_LLMD_IMAGE_NAME} ${LLMDBENCH_LLMD_IMAGE_TAG} 0)"
    modelCommand: ${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_MODEL_COMMAND}
    $(add_command $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_MODEL_COMMAND)
    args:
      $(add_command_line_options ${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_ARGS})
    env:
      - name: VLLM_IS_PREFILL
        value: "1"
      - name: VLLM_NIXL_SIDE_CHANNEL_HOST
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      - name: HF_HOME
        value: ${LLMDBENCH_VLLM_STANDALONE_PVC_MOUNTPOINT}
      $(add_additional_env_to_yaml $LLMDBENCH_VLLM_COMMON_ENVVARS_TO_YAML)
    resources:
      limits:
        memory: $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_MEM
        cpu: "$LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_NR"
        $(echo "$LLMDBENCH_VLLM_COMMON_ACCELERATOR_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_ACCELERATOR_NR}\"")
        $(echo "$LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_NR}\"" | $LLMDBENCH_CONTROL_SCMD -e 's/^: \"\"//')
      requests:
        memory: $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_MEM
        cpu: "$LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_NR"
        $(echo "$LLMDBENCH_VLLM_COMMON_ACCELERATOR_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_ACCELERATOR_NR}\"")
        $(echo "$LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_RESOURCE: \"${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_NR}\"" | $LLMDBENCH_CONTROL_SCMD -e 's/^: \"\"//')
    startupProbe:
      httpGet:
        path: /health
        port: ${LLMDBENCH_VLLM_COMMON_INFERENCE_PORT}
      failureThreshold: 60
      initialDelaySeconds: ${LLMDBENCH_VLLM_COMMON_INITIAL_DELAY_PROBE}
      periodSeconds: 30
      timeoutSeconds: 5
    livenessProbe:
      tcpSocket:
        port: ${LLMDBENCH_VLLM_COMMON_INFERENCE_PORT}
      failureThreshold: 3
      periodSeconds: 5
    readinessProbe:
      httpGet:
        path: /health
        port: ${LLMDBENCH_VLLM_COMMON_INFERENCE_PORT}
      failureThreshold: 3
      periodSeconds: 5
    volumeMounts:
    - name: metrics-volume
      mountPath: /.config
    - name: shm
      mountPath: /dev/shm
    - name: torch-compile-cache
      mountPath: /.cache
  volumes:
  - name: metrics-volume
    emptyDir: {}
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: "16Gi"
  - name: torch-compile-cache
    emptyDir: {}
EOF

    sanitized_model_name=$(model_attribute $model as_label)

    announce "🚀 Installing helm chart \"ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}\" via helmfile..."
    llmdbench_execute_cmd "helmfile --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} --kubeconfig ${LLMDBENCH_CONTROL_WORK_DIR}/environment/context.ctx --selector name=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE} apply -f $LLMDBENCH_CONTROL_WORK_DIR/setup/helm/${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}/helmfile.yaml --skip-diff-on-install" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
    announce "✅ ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE} helm chart deployed successfully"

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS -gt 0 ]]; then
      announce "⏳ waiting for (decode) pods serving model ${model} to be created..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=$((LLMDBENCH_CONTROL_WAIT_TIMEOUT / 2))s --for=create pod -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=decode" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE} 1 2
      announce "✅ (decode) pods serving model ${model} created"
    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS -gt 0 ]]; then
      announce "⏳ waiting for (prefill) pods serving model ${model} to be created..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=$((LLMDBENCH_CONTROL_WAIT_TIMEOUT / 2))s --for=create pod -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=prefill" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE} 1 2
      announce "✅ (prefill) pods serving model ${model} created"
    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS -gt 0 ]]; then
      announce "⏳ Waiting for (decode) pods serving model ${model} to be in \"Running\" state (timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s)..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s --for=jsonpath='{.status.phase}'=Running pod  -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=decode" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
      announce "🚀 (decode) pods serving model ${model} running"
    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS -gt 0 ]]; then
      announce "⏳ Waiting for (prefill) pods serving model ${model} to be in \"Running\" state (timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s)..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s --for=jsonpath='{.status.phase}'=Running pod  -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=prefill" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
      announce "🚀 (prefill) pods serving model ${model} running"
    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS -gt 0 ]]; then
      announce "⏳ Waiting for (decode) pods serving ${model} to be Ready (timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s)..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s --for=condition=Ready=True pod -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=decode" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
      announce "🚀 (decode) pods serving model ${model} ready"

      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} logs --tail=-1 --prefix=true -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=decode > ${LLMDBENCH_CONTROL_WORK_DIR}/setup/logs/llm-d-decode.log" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}

    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS -gt 0 ]]; then
      announce "⏳ Waiting for (prefill) pods serving ${model} to be Ready (timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s)..."
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} wait --timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s --for=condition=Ready=True pod -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=prefill" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
      announce "🚀 (prefill) pods serving model ${model} ready"

      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} logs --tail=-1 --prefix=true -l llm-d.ai/model=ms-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-llm-d-modelservice,llm-d.ai/role=prefill > ${LLMDBENCH_CONTROL_WORK_DIR}/setup/logs/llm-d-prefill.log" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}

    fi

    if [[ $LLMDBENCH_VLLM_MODELSERVICE_ROUTE -ne 0 && $LLMDBENCH_CONTROL_DEPLOY_IS_OPENSHIFT -ne 0 ]]; then
      is_route=$(${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} get route -o name --ignore-not-found | grep -E "/${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-inference-gateway-route$" || true)
      if [[ -z $is_route ]]
      then
        announce "📜 Exposing pods serving model ${model} as service..."
        llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_VLLM_COMMON_NAMESPACE} expose service/infra-${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-inference-gateway --target-port=${LLMDBENCH_VLLM_COMMON_INFERENCE_PORT} --name=${LLMDBENCH_VLLM_MODELSERVICE_RELEASE}-inference-gateway-route" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
        announce "✅ Service for pods service model ${model} created"
      fi
      announce "✅ Model \"${model}\" and associated service deployed."
    fi

    announce "✅ modelservice completed model deployment"

    unset LLMDBENCH_DEPLOY_CURRENT_MODEL
  done

else
  announce "⏭️ Environment types are \"${LLMDBENCH_DEPLOY_METHODS}\". Skipping this step."
fi
