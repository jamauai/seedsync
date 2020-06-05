# Copyright 2017, Inderpreet Singh, All rights reserved.

# Catch sigterms
# See: https://stackoverflow.com/a/52159940
export SHELL:=/bin/bash
export SHELLOPTS:=$(if $(SHELLOPTS),$(SHELLOPTS):)pipefail:errexit
.ONESHELL:

# Color outputs
red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`

ROOTDIR:=$(shell realpath .)
SOURCEDIR:=$(shell realpath ./src)
BUILDDIR:=$(shell realpath ./build)

#DOCKER_BUILDKIT_FLAGS=BUILDKIT_PROGRESS=plain
DOCKER=${DOCKER_BUILDKIT_FLAGS} DOCKER_BUILDKIT=1 docker
DOCKER_COMPOSE=${DOCKER_BUILDKIT_FLAGS} COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_BUILDKIT=1 docker-compose

.PHONY: builddir deb docker-image clean

all: deb docker-image

builddir:
	mkdir -p ${BUILDDIR}

scanfs: builddir
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/deb/Dockerfile \
		--target seedsync_build_scanfs_export \
		--output ${BUILDDIR} \
		${ROOTDIR}

deb: builddir
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/deb/Dockerfile \
		--target seedsync_build_deb_export \
		--output ${BUILDDIR} \
		${ROOTDIR}

docker-image:
	# scanfs image
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/deb/Dockerfile \
		--target seedsync_build_scanfs_export \
		--tag seedsync/build/scanfs/export \
		${ROOTDIR}

	# angular html export
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/deb/Dockerfile \
		--target seedsync_build_angular_export \
		--tag seedsync/build/angular/export \
		${ROOTDIR}

	# final image
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/docker-image/Dockerfile \
		--target seedsync_run \
		--tag seedsync:latest \
		${ROOTDIR}

tests-python:
	# python run
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/docker-image/Dockerfile \
		--target seedsync_run_python_env \
		--tag seedsync/run/python/env \
		${ROOTDIR}
	# python tests
	$(DOCKER_COMPOSE) \
		-f ${SOURCEDIR}/docker/test/python/compose.yml \
		build

run-tests-python: tests-python
	$(DOCKER_COMPOSE) \
		-f ${SOURCEDIR}/docker/test/python/compose.yml \
		up --force-recreate

tests-angular:
	# angular build
	$(DOCKER) build \
		-f ${SOURCEDIR}/docker/build/deb/Dockerfile \
		--target seedsync_build_angular_env \
		--tag seedsync/build/angular/env \
		${ROOTDIR}
	# angular tests
	$(DOCKER_COMPOSE) \
		-f ${SOURCEDIR}/docker/test/angular/compose.yml \
		build

run-tests-angular: tests-angular
	$(DOCKER_COMPOSE) \
		-f ${SOURCEDIR}/docker/test/angular/compose.yml \
		up --force-recreate

tests-e2e-deps:
	# deb pre-reqs
	$(DOCKER) build \
		${SOURCEDIR}/docker/stage/deb/ubuntu-systemd/ubuntu-16.04-systemd \
		-t ubuntu-systemd:16.04
	$(DOCKER) build \
		${SOURCEDIR}/docker/stage/deb/ubuntu-systemd/ubuntu-18.04-systemd \
		-t ubuntu-systemd:18.04
	$(DOCKER) build \
		${SOURCEDIR}/docker/stage/deb/ubuntu-systemd/ubuntu-20.04-systemd \
		-t ubuntu-systemd:20.04

	# Setup docker for the systemd container
	# See: https://github.com/solita/docker-systemd
	$(DOCKER) run --rm --privileged -v /:/host solita/ubuntu-systemd setup

run-tests-e2e: tests-e2e-deps
	# Check our settings
	@if [[ -z "${SEEDSYNC_VERSION}" ]] && [[ -z "${SEEDSYNC_DEB}" ]]; then \
		echo "${red}ERROR: One of SEEDSYNC_VERSION or SEEDSYNC_DEB must be set${reset}"; exit 1; \
	elif [[ ! -z "${SEEDSYNC_VERSION}" ]] && [[ ! -z "${SEEDSYNC_DEB}" ]]; then \
	  	echo "${red}ERROR: Only one of SEEDSYNC_VERSION or SEEDSYNC_DEB must be set${reset}"; exit 1; \
  	fi

	@if [[ ! -z "${SEEDSYNC_DEB}" ]] ; then \
		if [[ -z "${SEEDSYNC_OS}" ]] ; then \
			echo "${red}ERROR: SEEDSYNC_OS is required for DEB e2e test${reset}"; \
			echo "${red}Options include: ubu1604, ubu1804, ubu2004${reset}"; exit 1; \
		fi
	fi

	# Set the flags
	COMPOSE_FLAGS="-f ${SOURCEDIR}/docker/test/e2e/compose.yml "
	COMPOSE_RUN_FLAGS=""
	if [[ ! -z "${SEEDSYNC_DEB}" ]] ; then
		COMPOSE_FLAGS+="-f ${SOURCEDIR}/docker/stage/deb/compose.yml "
		COMPOSE_FLAGS+="-f ${SOURCEDIR}/docker/stage/deb/compose-${SEEDSYNC_OS}.yml "
	fi
	if [[ ! -z "${SEEDSYNC_VERSION}" ]] ; then \
		COMPOSE_FLAGS+="-f ${SOURCEDIR}/docker/stage/docker-image/compose.yml "
	fi
	if [[ "${DEV}" = "1" ]] ; then
		COMPOSE_FLAGS+="-f ${SOURCEDIR}/docker/test/e2e/compose-dev.yml "
	else \
  		COMPOSE_RUN_FLAGS+="-d"
	fi
	echo "${green}COMPOSE_FLAGS=$${COMPOSE_FLAGS}${reset}"

	# Set up Ctrl-C handler
	function tearDown {
		$(DOCKER_COMPOSE) \
			$${COMPOSE_FLAGS} \
			stop
	}
	trap tearDown EXIT

	# Build the test
	$(DOCKER_COMPOSE) \
		$${COMPOSE_FLAGS} \
		build

	# Run the test
	$(DOCKER_COMPOSE) \
		$${COMPOSE_FLAGS} \
		up --force-recreate \
		$${COMPOSE_RUN_FLAGS}

	if [[ "${DEV}" != "1" ]] ; then
		$(DOCKER) logs -f seedsync_test_e2e
	fi

run-remote-server:
	$(DOCKER) container rm -f seedsync_test_e2e_remote-dev
	$(DOCKER) run \
		-it --init \
		-p 1234:1234 \
		--name seedsync_test_e2e_remote-dev \
		seedsync/test/e2e/remote

clean:
	rm -rf ${BUILDDIR}
