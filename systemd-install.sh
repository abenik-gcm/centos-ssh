#!/usr/bin/env bash

# Change working directory
DIR_PATH="$( if [[ $( echo "${0%/*}" ) != $( echo "${0}" ) ]] ; then cd "$( echo "${0%/*}" )"; fi; pwd )"
if [[ ${DIR_PATH} == */* ]] && [[ ${DIR_PATH} != $( pwd ) ]] ; then
	cd ${DIR_PATH}
fi

source run.conf

is_coreos_distribution ()
{
	if [[ -n $( [[ -e /etc/os-release ]] && grep ^ID=coreos$ /etc/os-release ) ]]; then
		return 0
	fi

	return 1
}

replace_etcd_service_name ()
{
	local FILE_PATH=${1}

	if [[ -z ${FILE_PATH} ]]; then
		echo "Path to the service's unit file is required."
		return 1
	fi

	if ! [[ -s ${FILE_PATH} ]]; then
		echo "Unit file not found."
		return 1
	fi

	# CoreOS uses etcd.service and etcd2.service for version 1 and 2 of ETCD 
	# respectively but has both available. Use etcd2.service in the systemd 
	# unit file and rename for other distributions where etcd.service is the 
	# only name used.
	if is_coreos_distribution; then
		echo "---> CoreOS distribution."
		echo " ---> Renaming etcd.service to etcd2.service in unit file."
		sed -i -e 's~etcd.service~etcd2.service~g' ${FILE_PATH}
	fi
}

# Abort if systemd not supported
if ! type -p systemctl &> /dev/null; then
	printf -- "${COLOUR_NEGATIVE}--->${COLOUR_RESET} %s\n" 'Systemd installation not supported.'
	exit 1
fi

# Abort if not run by root user or with sudo
if [[ ${EUID} -ne 0 ]]; then
	printf -- "${COLOUR_NEGATIVE}--->${COLOUR_RESET} %s\n" 'Please run as root.'
	exit 1
fi

# Copy systemd unit-files into place.
cp ${SERVICE_UNIT_TEMPLATE_NAME} /etc/systemd/system/
cp ${SERVICE_UNIT_REGISTER_TEMPLATE_NAME} /etc/systemd/system/
replace_etcd_service_name /etc/systemd/system/${SERVICE_UNIT_TEMPLATE_NAME}
replace_etcd_service_name /etc/systemd/system/${SERVICE_UNIT_REGISTER_TEMPLATE_NAME}

systemctl daemon-reload

printf -- "---> Installing %s\n" ${SERVICE_UNIT_INSTANCE_NAME}
systemctl enable -f ${SERVICE_UNIT_INSTANCE_NAME}
systemctl enable -f ${SERVICE_UNIT_REGISTER_INSTANCE_NAME}
systemctl restart ${SERVICE_UNIT_INSTANCE_NAME} &
PIDS[0]=${!}

# Tail the systemd unit logs unitl installation completes
journalctl -fn 0 -u ${SERVICE_UNIT_INSTANCE_NAME} &
PIDS[1]=${!}

# Wait for installtion to complete
[[ -n ${PIDS[0]} ]] && wait ${PIDS[0]}

# Allow time for the container bootstrap to complete
sleep 5
kill -15 ${PIDS[1]}
wait ${PIDS[1]} 2> /dev/null

if systemctl -q is-active ${SERVICE_UNIT_INSTANCE_NAME} && systemctl -q is-active ${SERVICE_UNIT_REGISTER_INSTANCE_NAME}; then
	printf -- "---> Service unit is active: %s\n" "$(systemctl list-units --type=service | grep "^[ ]*${SERVICE_UNIT_INSTANCE_NAME}")"
	printf -- "---> Service register unit is active: %s\n" "$(systemctl list-units --type=service | grep "^[ ]*${SERVICE_UNIT_REGISTER_INSTANCE_NAME}")"
	printf -- "${COLOUR_POSITIVE} --->${COLOUR_RESET} %s\n" 'Install complete'
else
	printf -- "\nService status:\n"
	systemctl status -ln 50 ${SERVICE_UNIT_INSTANCE_NAME}
	printf -- "\n${COLOUR_NEGATIVE} --->${COLOUR_RESET} %s\n" 'Install error'
fi
