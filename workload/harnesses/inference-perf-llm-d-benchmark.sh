#!/usr/bin/env bash

echo Using experiment result dir: "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR"
mkdir -p "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR"
pushd "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR"
yq '.storage["local_storage"]["path"] = '\"${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR}\" <"/workspace/profiles/inference-perf/${LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME}" -y >${LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME}
inference-perf --config_file "$(realpath ./${LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME})" > >(tee -a $LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR/stdout.log) 2> >(tee -a $LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR/stderr.log >&2)
export LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC=$?
exit $LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC
