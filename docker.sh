#!/bin/bash

set -ex

# default globals
BUILD_LOCATION="${BUILD_LOCATION:-/opt/emq_packages/free}"
EMQX_NAME="${EMQX_NAME:-emqx}"
TARGET="${TARGET:-emqx/emqx}"
EMQX_DELOPY="${EMQX_DELOPY:-cloud}"
QEMU_ARCH="${QEMU_ARCH:-x86_64}"
ARCH="${ARCH:-amd64}"
QEMU_VERSION="${QEMU_VERSION:-v3.0.0}"

# versioning
GIT_DESCRIBE="$(git describe --tags --always)"
TAG_VSN="$(echo "$GIT_DESCRIBE" | grep -oE "v[0-9]+\.[0-9]+(\.[0-9]+)?")"
EMQX_VERSION="${EMQX_VERSION:-${TAG_VSN:-develop}}"
BUILD_VERSION="${BUILD_VERSION:-${EMQX_VERSION}}"

main() {
    case $1 in
        "prepare")
            docker_prepare
            ;;
        "build")
            docker_build
            ;;
        "test")
            docker_test
            ;;
        "tag")
            docker_tag
            ;;
        "save")
            docker_save
            ;;
        "push")
            docker_push
            ;;
        "clean")
            docker_clean
            ;;
        "manifest-list")
            docker_manifest_list
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

usage() {
    echo "Usage:"
    echo "$0 prepare"
    echo "$0 build | test | tag | save | push | clean | manifest-list"
}

docker_prepare() {
    # Prepare the machine before any code installation scripts
    setup_dependencies

    # Update docker configuration to enable docker manifest command
    update_docker_configuration

    # Prepare qemu to build images other then x86_64 on travis
    prepare_qemu
}

package_build() {
  rm -rf emqx-${ARCH}
  mkdir emqx-${ARCH}
  docker create --rm \
    --name=${EMQX_NAME}-build-${ARCH} \
    -v "${PWD}/emqx-${ARCH}:/emqx-${ARCH}" \
    -e "SYSTEM=alpine3.8-${ARCH}" \
    -e "EMQX_VERSION=${EMQX_VERSION}" \
    -e "BUILD_PROJECT=emqx" \
    -e "EMQX_NAME=${EMQX_NAME}" \
    -e "DEPLOY=${EMQX_DELOPY}" \
    emqx/build-env:alpine3.8-${ARCH} \
    /bin/bash -c "git clone -b $EMQX_VERSION https://github.com/17204105/emqx-rel.git /emqx_rel \
    && cd /emqx_rel \
    && make distclean \
    && git checkout relx \
    && make \
    && mv _rel/emqx/* /emqx-${ARCH}"

  docker start -i ${EMQX_NAME}-build-${ARCH}
}

docker_build() {
  # Build Docker image
  echo "DOCKER BUILD: Build Docker image."
  echo "DOCKER BUILD: build version -> ${BUILD_VERSION}."
  echo "DOCKER BUILD: build from -> ${BUILD_FROM}."
  echo "DOCKER BUILD: arch - ${ARCH}."
  echo "DOCKER BUILD: qemu arch - ${QEMU_ARCH}."
  echo "DOCKER BUILD: docker repo - ${TARGET}. "
  echo "DOCKER BUILD: emqx delopy - ${EMQX_DELOPY}."
  echo "DOCKER BUILD: emqx version - ${EMQX_VERSION}."

  if [ ! -f ${BUILD_LOCATION}/${EMQX_NAME}-alpine3.8-${ARCH}-${EMQX_VERSION}.zip ]; then
    package_build
  else
    rm -rf ./emqx ./emqx-${ARCH}
    zipname=`basename ${BUILD_LOCATION}/${EMQX_NAME}-alpine3.8-${ARCH}-${EMQX_VERSION}.zip`
    unzip -o ${BUILD_LOCATION}/$zipname -d ./
    mv `unzip -l ${BUILD_LOCATION}/$zipname | awk '{if(NR == 4){ print $4}}'` ./emqx-${ARCH}
  fi

  docker build --no-cache \
    --build-arg BUILD_REF=${TRAVIS_COMMIT:-${GIT_DESCRIBE}} \
    --build-arg BUILD_DATE=$(date +"%Y-%m-%dT%H:%M:%SZ") \
    --build-arg BUILD_VERSION=${BUILD_VERSION} \
    --build-arg BUILD_FROM=${ARCH}/alpine:3.8 \
    --build-arg ARCH=${ARCH} \
    --build-arg QEMU_ARCH=${QEMU_ARCH} \
    --tag ${TARGET}:build-${ARCH} .
}

docker_test() {
  echo "DOCKER TEST: Test Docker image."
  echo "DOCKER TEST: testing image -> ${TARGET}:build-${ARCH}."

  docker run -d \
    -e EMQX_ZONE__EXTERNAL__SERVER_KEEPALIVE=60 \
    -e EMQX_MQTT__MAX_TOPIC_ALIAS=10 \
    --network=host \
    --name=test-${ARCH} \
    ${TARGET}:build-${ARCH}
  if [ $? -ne 0 ]; then
     echo "DOCKER TEST: FAILED - Docker container test-${ARCH} failed to start."
     exit 1
  else
     emqx_ver=$(sudo docker exec test-${ARCH} /opt/emqx/bin/emqx_ctl status |grep 'is running'|awk '{print $2}')
     IDLE_TIME=0
     while [[ -z $emqx_ver ]]
     do
     	if [[ $IDLE_TIME -gt 10 ]]
         then
         	  echo "DOCKER TEST: FAILED - Docker container test-${ARCH} failed to start."
            exit 1
         fi
         sleep 10
         IDLE_TIME=$((IDLE_TIME+1))
         emqx_ver=$(sudo docker exec test-${ARCH} /opt/emqx/bin/emqx_ctl status |grep 'is running'|awk '{print $2}')
     done
     if [[ ! -z $(echo $EMQX_VERSION | grep -oE "v[0-9]+\.[0-9]+(\.[0-9]+)?") && $EMQX_VERSION != $emqx_ver ]]
     then
         echo "DOCKER TEST: FAILED - Docker container test-${ARCH} version error."
         exit 1 
     fi
     echo "DOCKER TEST: PASSED - Docker container test-${ARCH} succeeded to start."
     # Paho test
     docker run -i --rm --network=host  python:3.7.2-alpine3.8 \
     sh -c "sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories \
     && apk update && apk add git \
     && git clone -b master https://github.com/17204105/paho.mqtt.testing.git \
     && cd paho.mqtt.testing/ \
     && python interoperability/client_test5.py"
     docker rm -f test-${ARCH}
  fi
}

docker_tag() {
    echo "DOCKER TAG: Tag Docker image."
    [[ -n  $(docker images -q ${TARGET}:build-arm64v8) ]] && docker tag ${TARGET}:build-arm64v8 ${TARGET}:${BUILD_VERSION}-arm64v8
    [[ -n  $(docker images -q ${TARGET}:build-arm32v6) ]] && docker tag ${TARGET}:build-arm32v6 ${TARGET}:${BUILD_VERSION}-arm32v6
    [[ -n  $(docker images -q ${TARGET}:build-amd64) ]] &&  docker tag ${TARGET}:build-amd64 ${TARGET}:${BUILD_VERSION}-amd64 &&  docker tag ${TARGET}:build-amd64 ${TARGET}:${BUILD_VERSION} 
}

docker_save() {
    echo "DOCKER SAVE: Save Docker image."  
    filename=${TARGET#"emqx/"}
    [[ -n  $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]] && docker save ${TARGET}:${BUILD_VERSION}-arm64v8 > ${filename}-docker-${BUILD_VERSION}-arm64v8 && zip -r -m ${filename}-docker-${BUILD_VERSION}-arm64v8.zip ${filename}-docker-${BUILD_VERSION}-arm64v8 
    [[ -n  $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && docker save ${TARGET}:${BUILD_VERSION}-arm32v6 > ${filename}-docker-${BUILD_VERSION}-arm32v6 && zip -r -m ${filename}-docker-${BUILD_VERSION}-arm32v6.zip ${filename}-docker-${BUILD_VERSION}-arm32v6
    [[ -n  $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64) ]] && docker save ${TARGET}:${BUILD_VERSION}-amd64 > ${filename}-docker-${BUILD_VERSION}-amd64 && zip -r -m ${filename}-docker-${BUILD_VERSION}-amd64.zip ${filename}-docker-${BUILD_VERSION}-amd64 
    [[ -n  $(docker images -q ${TARGET}:${BUILD_VERSION}) ]] && docker save ${TARGET}:${BUILD_VERSION} > ${filename}-docker-${BUILD_VERSION} && zip -r -m ${filename}-docker-${BUILD_VERSION}.zip ${filename}-docker-${BUILD_VERSION}

}

docker_push() {
  echo "DOCKER PUSH: Push Docker image."
  echo "DOCKER PUSH: pushing - ${TARGET}:${BUILD_VERSION}."
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]] && docker push ${TARGET}:${BUILD_VERSION}-arm64v8 
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && docker push ${TARGET}:${BUILD_VERSION}-arm32v6 
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64) ]] && docker push ${TARGET}:${BUILD_VERSION}-amd64  
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}) ]] && docker push ${TARGET}:${BUILD_VERSION}

  if [[ ! -z $(echo $BUILD_VERSION | grep -oE "v[0-9]+\.[0-9]+(\.[0-9]+)?") ]];then
    docker tag ${TARGET}:${BUILD_VERSION} ${TARGET}:latest
    docker push ${TARGET}:latest
  fi
}


docker_clean() {
  echo "DOCKER CLEAN: Clean Docker image."
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64) ]] && docker rmi -f $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64)
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && docker rmi -f $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) 
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]] && docker rmi -f $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) 
}

docker_manifest_list() {
  echo "DOCKER BUILD: target -> ${TARGET}."
  echo "DOCKER BUILD: build version -> ${BUILD_VERSION}."

  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64) ]] || { echo "${TARGET}:${BUILD_VERSION}-amd64 does not exist."; exit 1; } 

  # Create and push manifest lists, displayed as FIFO
  echo "DOCKER MANIFEST: Create and Push docker manifest lists."
  docker_manifest_list_version

  # Create manifest list latest
  echo "DOCKER MANIFEST: Create and Push docker manifest list LATEST."
  docker_manifest_list_latest;

  docker_manifest_list_version_os_arch
}

docker_manifest_list_version() {
  # Manifest Create BUILD_VERSION
  echo "DOCKER MANIFEST: Create and Push docker manifest list - ${TARGET}:${BUILD_VERSION}."
  if [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]];then
    docker manifest create ${TARGET}:${BUILD_VERSION} \
      ${TARGET}:${BUILD_VERSION}-amd64 \
      ${TARGET}:${BUILD_VERSION}-arm32v6 \
      ${TARGET}:${BUILD_VERSION}-arm64v8
  elif [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]];then
    docker manifest create ${TARGET}:${BUILD_VERSION} \
      ${TARGET}:${BUILD_VERSION}-amd64 \
      ${TARGET}:${BUILD_VERSION}-arm64v8
  else 
    docker manifest create ${TARGET}:${BUILD_VERSION} \
      ${TARGET}:${BUILD_VERSION}-amd64 
  fi

  # Manifest Annotate BUILD_VERSION
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && docker manifest annotate ${TARGET}:${BUILD_VERSION} ${TARGET}:${BUILD_VERSION}-arm32v6 --os=linux --arch=arm --variant=v6
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]] && docker manifest annotate ${TARGET}:${BUILD_VERSION} ${TARGET}:${BUILD_VERSION}-arm64v8 --os=linux --arch=arm64 --variant=v8

  # Manifest Push BUILD_VERSION
  docker manifest push ${TARGET}:${BUILD_VERSION}
}

docker_manifest_list_latest() {
  # Manifest Create latest
  echo "DOCKER MANIFEST: Create and Push docker manifest list - ${TARGET}:latest."
  if [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]];then
    docker manifest create ${TARGET}:latest \
      ${TARGET}:${BUILD_VERSION}-amd64 \
      ${TARGET}:${BUILD_VERSION}-arm32v6 \
      ${TARGET}:${BUILD_VERSION}-arm64v8
  elif [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]];then
    docker manifest create ${TARGET}:latest \
      ${TARGET}:${BUILD_VERSION}-amd64 \
      ${TARGET}:${BUILD_VERSION}-arm64v8
  else
    docker manifest create ${TARGET}:latest \
    ${TARGET}:${BUILD_VERSION}-amd64 
  fi
  

  # Manifest Annotate BUILD_VERSION
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]] && docker manifest annotate ${TARGET}:latest ${TARGET}:${BUILD_VERSION}-arm32v6 --os=linux --arch=arm --variant=v6
  [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]] && docker manifest annotate ${TARGET}:latest ${TARGET}:${BUILD_VERSION}-arm64v8 --os=linux --arch=arm64 --variant=v8

  # Manifest Push BUILD_VERSION
  docker manifest push ${TARGET}:latest
}

docker_manifest_list_version_os_arch() {
  if [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-amd64) ]];then
    # Manifest Create alpine-amd64
    echo "DOCKER MANIFEST: Create and Push docker manifest list - ${TARGET}:${BUILD_VERSION}-amd64."
    docker manifest create ${TARGET}:${BUILD_VERSION}-amd64 \
      ${TARGET}:${BUILD_VERSION}-amd64

    # Manifest Push alpine-amd64
    docker manifest push ${TARGET}:${BUILD_VERSION}-amd64
  fi

  if [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm32v6) ]];then
    # Manifest Create alpine-arm32v6
    echo "DOCKER MANIFEST: Create and Push docker manifest list - ${TARGET}:${BUILD_VERSION}-arm32v6."
    docker manifest create ${TARGET}:${BUILD_VERSION}-arm32v6 \
      ${TARGET}:${BUILD_VERSION}-arm32v6

    # Manifest Annotate alpine-arm32v6
    docker manifest annotate ${TARGET}:${BUILD_VERSION}-arm32v6 ${TARGET}:${BUILD_VERSION}-arm32v6 --os=linux --arch=arm --variant=v6

    # Manifest Push alpine-arm32v6
    docker manifest push ${TARGET}:${BUILD_VERSION}-arm32v6
  fi

  if [[ -n $(docker images -q ${TARGET}:${BUILD_VERSION}-arm64v8) ]];then
    # Manifest Create alpine-arm64v8
    echo "DOCKER MANIFEST: Create and Push docker manifest list - ${TARGET}:${BUILD_VERSION}-arm64v8."
    docker manifest create ${TARGET}:${BUILD_VERSION}-arm64v8 \
      ${TARGET}:${BUILD_VERSION}-arm64v8

    # Manifest Annotate alpine-arm64v8
    docker manifest annotate ${TARGET}:${BUILD_VERSION}-arm64v8 ${TARGET}:${BUILD_VERSION}-arm64v8 --os=linux --arch=arm64 --variant=v8

    # Manifest Push alpine-arm64v8
    docker manifest push ${TARGET}:${BUILD_VERSION}-arm64v8
  fi
}

setup_dependencies() {
  echo "PREPARE: Setting up dependencies."

  sudo apt update -y
  sudo apt install --only-upgrade docker-ce -y
}

update_docker_configuration() {
  echo "PREPARE: Updating docker configuration"

  mkdir -p $HOME/.docker

  # enable experimental to use docker manifest command
  echo '{
    "experimental": "enabled"
  }' | tee $HOME/.docker/config.json

  # enable experimental
  echo '{
    "experimental": true,
    "storage-driver": "overlay2",
    "max-concurrent-downloads": 50,
    "max-concurrent-uploads": 50
  }' | sudo tee /etc/docker/daemon.json

  sudo service docker restart
}

prepare_qemu(){
    echo "PREPARE: Qemu"
    # Prepare qemu to build non amd64 / x86_64 images
    docker run --rm --privileged multiarch/qemu-user-static:register --reset
    rm -rf tmp
    mkdir -p tmp
    pushd tmp &&
    curl -L -o qemu-x86_64-static.tar.gz https://github.com/multiarch/qemu-user-static/releases/download/$QEMU_VERSION/qemu-x86_64-static.tar.gz && tar xzf qemu-x86_64-static.tar.gz &&
    curl -L -o qemu-arm-static.tar.gz https://github.com/multiarch/qemu-user-static/releases/download/$QEMU_VERSION/qemu-arm-static.tar.gz && tar xzf qemu-arm-static.tar.gz &&
    curl -L -o qemu-aarch64-static.tar.gz https://github.com/multiarch/qemu-user-static/releases/download/$QEMU_VERSION/qemu-aarch64-static.tar.gz && tar xzf qemu-aarch64-static.tar.gz &&
    popd
}

main $1
