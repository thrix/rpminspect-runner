#!/bin/bash

# Usage:
# ./rpminspect_runner.sh $TASK_ID $PREVIOUS_TAG $TEST_NAME
#
# The script recognizes following environment variables:
# RPMINSPECT_CONFIG - path to the rpminspect config file
# RPMINSPECT_PROFILE_NAME - rpminspect profile to use
# PREVIOUS_TAG - koji tag where to look for previous builds
# DEFAULT_RELEASE_STRING - release string to use in case builds
#                          don't have them (e.g.: missing ".fc34")
# RPMINSPECT_WORKDIR - workdir where to cache downloaded builds
# KOJI_BIN - path where to find "koji" binary
# ARCHES - a comma-separated list of architectures to test (e.g.: x86_64,noarch,src)
# IS_MODULE - "yes" if the given TASK_ID is a module task ID from MBS
# MBS_API_URL - Module Build System (MBS) API URL
# TESTS - a comma-separated list of inspections to run

set -e

trap fix_rc EXIT SIGINT SIGSEGV
fix_rc() {
    retval=$?
    # rpminspect status codes:
    # RI_INSPECTION_SUCCESS = 0,   /* inspections passed */
    # RI_INSPECTION_FAILURE = 1,   /* inspections failed */
    # RI_PROGRAM_ERROR = 2         /* program errored in some way */
    #
    # These status codes need to be translated to the TMT status codes,
    # so TMT can correctly recognize failures, errors, and successes.
    if [ ${retval} -gt 3 ]; then
        # something unexpected happened — treat it as an infra error
        exit 2
    fi
    exit $retval
}

config=${RPMINSPECT_CONFIG:-/usr/share/rpminspect/fedora.yaml}
koji_bin=${KOJI_BIN:-/usr/bin/koji}

task_id=${1}
previous_tag=${2}
test_name=${3}

# In case there is no dist tag (like ".fc34") in the package name,
# rpminspect doesn't know which test configuration to use
default_release_string=${DEFAULT_RELEASE_STRING}

profile_name=${RPMINSPECT_PROFILE_NAME}

arches=${ARCHES}

is_module="${IS_MODULE}"

tests="${TESTS}"

get_name_from_nvr() {
    # Extract package name (N) from NVR.
    # Params:
    # $1: NVR
    local nvr=$1
    # Pfff... close your eyes here...
    name=$(echo $nvr | sed 's/^\(.*\)-\([^-]\{1,\}\)-\([^-]\{1,\}\)$/\1/')
    echo -n ${name}
}

get_ns_from_module_nvr() {
    # Extract "module_name-stream" (ns) from NVR.
    # Params:
    # $1: NVR
    local nvr=$1
    name=$(echo $nvr | sed 's/^\(.*[^-]\{1,\}\)-\([^-]\{1,\}\)$/\1/')
    echo -n ${name}
}

quit_if_disabled() {
    # Quit the script if the inspection is disabled in config/profile file.
    # Params:
    # $1: inspection name
    local inspection_name=$1

    is_enabled=$(python3 -c "\
import yaml; \
import sys; \
is_enabled = yaml.safe_load(open(sys.argv[1])).get('inspections', {}).get(sys.argv[2], True); \
print('yes', end='') if is_enabled else print('no', end='')" "effective_rpminspect.yaml" "${inspection_name}")
    if [ "${is_enabled}" == "no" ]; then
        echo
        echo "This inspection is disabled."
        exit 0
    fi
}

get_after_build() {
    # Convert task id to NVR.
    # Params:
    # $1: task id
    local task_id=$1
    after_build=$(basename $("$koji_bin" taskinfo -v -r "$task_id" | grep "SRPM: " | head -1 | awk '{ print $2 }' | sed 's|\.src.rpm$||g'))
    echo -n ${after_build}
}

get_before_build() {
    # Find previous build for given NVR.
    # The assumption is that the given NVR is not tagged in the "previous_tag".
    # If the NVR is tagger in the "previous_tag", then it has to be the latest NVR
    # for that packages in that tag.
    # Params:
    # $1: NVR
    # $2: Koji tag where to look for older builds
    local after_build=$1
    local previous_tag=$2
    local package_name=$(get_name_from_nvr $after_build)
    before_build=$(${koji_bin} list-tagged --latest --inherit --quiet ${previous_tag} ${package_name} | awk -F' ' '{ print $1 }')
    if [ "${before_build}" == "${after_build}" ]; then

	# Reset $before_build so we can return an empty string if no previous builds are found
	before_build=''

	# Look back 2 builds to see if we have an older version to compare against
        latest_two=$(${koji_bin} list-tagged --latest-n 2 --inherit --quiet ${previous_tag} ${package_name} | awk -F' ' '{ print $1 }')
        for nvr in $latest_two; do
            if [ "${nvr}" != "${after_build}" ]; then
                before_build=${nvr}
                break
            fi
        done

    fi
    # Provide either an empty string or the previous build
    echo -n ${before_build}
}

get_before_module_build() {
    # Find previous module build for given NVR.
    # The assumption is that the given NVR is not tagged in the "previous_tag".
    # If the NVR is tagger in the "previous_tag", then it has to be the latest NVR
    # for that module in that tag.
    # Params:
    # $1: NVR
    # $2: Koji tag where to look for older builds
    local after_build=$1
    local previous_tag=$2
    local name=$(get_name_from_nvr $after_build)
    local name_stream=$(get_ns_from_module_nvr $after_build)
    # TODO: it would be better to actually compare NVRs instead of assuming that the last NVR in the list is the latest...
    before_build=$(${koji_bin} list-tagged --inherit --quiet ${previous_tag} ${name} | grep "^${name_stream}" | awk -F' ' '{ print $1 }' | tail -1)

    if [ "${before_build}" == "${after_build}" ]; then
        # Reset $before_build so we can return an empty string if no previous builds are found
        before_build=''

        # Get the latest-1 NVR
        before_build_candidate=$(${koji_bin} list-tagged --inherit --quiet ${previous_tag} ${name} | grep "^${name_stream}" | awk -F' ' '{ print $1 }' | tail -2 | head -1)
        if [ "${before_build_candidate}" != "${after_build}" ]; then
                before_build=${before_build_candidate}
        fi
    fi

    # Provide either an empty string or the previous build
    echo -n ${before_build}
}

workdir="${RPMINSPECT_WORKDIR:-/var/tmp/rpminspect/}${task_id}-${before_build}"
results_cache_dir="${RPMINSPECT_WORKDIR:-/var/tmp/rpminspect/}results_cache"
results_cached_file="${RPMINSPECT_WORKDIR:-/var/tmp/rpminspect/}cached"

mkdir -p ${workdir}
mkdir -p "${results_cache_dir}"

after_build_param="${task_id}"

before_build=''

# cache results — the following section should run in CI only once
if [ ! -f "${results_cached_file}" ]; then
    if [ "${is_module}" == "yes" ]; then

        module_info=$(curl "${MBS_API_URL}/module-build-service/1/module-builds/${task_id}")
        name=$(echo "${module_info}" | jq -r .name)
        stream=$(echo "${module_info}" | jq -r .stream)
        version=$(echo "${module_info}" | jq -r .version)
        context=$(echo "${module_info}" | jq -r .context)
        after_build="${name}-${stream}-${version}.${context}"

        if [ -n "$previous_tag" ]; then
            before_build=$(get_before_module_build "${after_build}" "${previous_tag}")
        fi
        after_build_param="${after_build}"
    else
        after_build=$(get_after_build "${task_id}")
        if [ -n "$previous_tag" ]; then
            before_build=$(get_before_build "${after_build}" "${previous_tag}")
        fi
    fi

    echo -n "${after_build}" > "${results_cache_dir}/after_build"
    echo -n "${before_build}" > "${results_cache_dir}/before_build"

    if [ ! -f "effective_rpminspect.yaml" ]; then
        # Get the effective config file
        /usr/bin/rpminspect -c ${config} \
                ${profile_name:+--profile=$profile_name} \
                -D > effective_rpminspect.yaml || :
    fi

    rpminspect_get_local_config.sh "${after_build}"

    # Update the virus dababase
    freshclam > freshclam.log 2>&1 || :

    # Update annobin
    # FIXME: we don't want to touch packages when the base image is Rawhide...
    #     We can uncomment this once the latest annocheck can be installed from a stable repo.
    #dnf update -y annobin* > update_annobin.log 2>&1 || :

    # Update the data package, but from COPR, not from the official Fedora repositories
    dnf update --disablerepo="fedora*" -y ${RPMINSPECT_PACKAGE_NAME} ${RPMINSPECT_DATA_PACKAGE_NAME} > update_rpminspect.log 2>&1 || :

    # Run all inspections and cache results
    /usr/bin/rpminspect -c ${config} \
            --workdir=${RPMINSPECT_WORKDIR} \
            --format=json \
            --output=results.json \
            --verbose \
            ${arches:+--arches=$arches} \
            ${default_release_string:+--release=$default_release_string} \
            ${profile_name:+--profile=$profile_name} \
            ${tests:+--tests=$tests} \
            ${before_build} \
            ${after_build_param} \
            > verbose.log 2>&1 || :

    # Convert JSON to text and store results of each inspection to a separate file
    rpminspect_json2text.py "${results_cache_dir}" results.json
    touch "${results_cached_file}"
fi

after_build=$(cat "${results_cache_dir}/after_build")
before_build=$(cat "${results_cache_dir}/before_build")

# Get description for current inspection
/usr/bin/rpminspect -l -v | awk -v RS= -v ORS='\n\n' "/    ${test_name}\n/" | sed -e 's/^[ \t]*//' | tail -n +2 > "${results_cache_dir}/${test_name}_description"

rpminspect_version=`rpm -q --qf "%{VERSION}-%{RELEASE}" ${RPMINSPECT_PACKAGE_NAME}`
data_version=`rpm -q --qf "%{VERSION}-%{RELEASE}" ${RPMINSPECT_DATA_PACKAGE_NAME}`

echo "rpminspect version: ${rpminspect_version} (with data package: ${data_version})"
echo "rpminspect profile: ${profile_name:-none}"
echo "new build: ${after_build}"
if [ -z "${before_build}" ]; then
    if [ -n "${previous_tag}" ]; then
        echo "old build: not found (in ${previous_tag} $(basename ${koji_bin}) tag)"
    fi
else
    echo "old build: ${before_build} (found in ${previous_tag} $(basename ${koji_bin}) tag)"
fi
echo
echo "Test description:"
cat "${results_cache_dir}/${test_name}_description"
echo "======================================== Test Output ========================================"

quit_if_disabled "${test_name}"

if [ -f "${results_cache_dir}/${test_name}_result" ]; then
    cat "${results_cache_dir}/${test_name}_result"
    rc=$(cat "${results_cache_dir}/${test_name}_status")
else
    # This inspection did not run (modularity inspection?)
    cat "${results_cache_dir}/skipped_result"
    rc=0  # success
fi

exit $((rc))
