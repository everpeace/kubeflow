set -exv

OPENMPI_DIR=/kubeflow/openmpi
BACKOFF_SECS=10
TIMEOUT_EXIT_CODE=124

wait_mpi_ready() {
  local workers=$1
  local max_retries=$2
  local mpi_exec_timeout=$3
  local retries=0

  until MPIEXEC_TIMEOUT=${mpi_exec_timeout} mpiexec -n ${workers} --hostfile ${OPENMPI_DIR}/assets/hostfile --allow-run-as-root -q sh -c 'echo $(hostname) is ready'; do
    sleep ${BACKOFF_SECS}

    retries=$(expr ${retries} + 1)
    if [ -n "${max_retries}" ] && [ ${retries} -ge ${max_retries} ]; then
      exit ${TIMEOUT_EXIT_CODE}
    fi
  done
}

wait_controller_signal() {
  local signal=$1
  local max_retries=$2
  local retries=0

  until [ -f ${OPENMPI_DIR}/data/.openmpi-controller/${signal} ]; do
    sleep ${BACKOFF_SECS}

    retries=$(expr ${retries} + 1)
    if [ -n "${max_retries}" ] && [ ${retries} -ge ${max_retries} ]; then
      exit ${TIMEOUT_EXIT_CODE}
    fi
  done
}

if [ $# -ne 5 ]; then
  echo "illegal number of parameters"
  exit 1
fi

role="$1"
workers="$2"
exec="$3"
timeout_secs="$4"
mpiexec_timeout_on_wait_mpi_ready="$5"
max_retries=$(expr ${timeout_secs} / ${BACKOFF_SECS})

# Set up openmpi
mkdir -p ${HOME}/.openmpi
cp ${OPENMPI_DIR}/assets/mca-params.conf ${HOME}/.openmpi

# Set up ssh
mkdir -p ${HOME}/.ssh
cp ${OPENMPI_DIR}/secrets/id_rsa ${HOME}/.ssh
chmod 400 ${HOME}/.ssh/id_rsa
cp ${OPENMPI_DIR}/secrets/id_rsa.pub ${HOME}/.ssh
cp ${OPENMPI_DIR}/secrets/authorized_keys ${HOME}/.ssh
cp ${OPENMPI_DIR}/assets/ssh_config ${HOME}/.ssh/config

SSHD_CONFIG=${OPENMPI_DIR}/assets/sshd_config
# when this runs by non-root user.
# we have to create ephemeral hostkeys
if [ "$(id -u)" != "0" ]; then
  mkdir -p ${HOME}/.sshd
  cp ${OPENMPI_DIR}/assets/sshd_config ${HOME}/.sshd/sshd_config
  SSHD_CONFIG=${HOME}/.sshd/sshd_config

  ssh-keygen -f ${HOME}/.sshd/host_rsa_key -C '' -N '' -t rsa
  ssh-keygen -f ${HOME}/.sshd/host_dsa_key -C '' -N '' -t dsa
  echo "HostKey ${HOME}/.sshd/host_rsa_key" >> ${SSHD_CONFIG}
  echo "HostKey ${HOME}/.sshd/host_dsa_key" >> ${SSHD_CONFIG}
fi

exit_code=0
if [ "${role}" = "master" ]; then
  # Wait until workers are ready.
  wait_mpi_ready ${workers} ${max_retries} ${mpiexec_timeout_on_wait_mpi_ready}

  # Run the exec command in master
  sh -c "${exec}" || exit_code=$?
else
  # Wait until controller finishes initialization.
  wait_controller_signal SIGCONT ${max_retries}

  # Start sshd in daemon mode
  /usr/sbin/sshd -e -f ${SSHD_CONFIG}

  # Block forever until controller terminates.
  wait_controller_signal SIGTERM
fi

exit ${exit_code}
