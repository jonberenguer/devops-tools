#!/bin/bash

# bash forklift-cli.sh build|deploy \
#        running-service-name|service-name \
#        volpassword \
#        [timestamp-value-for deploy]

# forklift of service
FORKLIFT_METHOD="$1"

possible_methods=("image-build" "build" "deploy")
is_found=false
for value in "${possible_methods[@]}"; do
  if [[ "$FORKLIFT_METHOD" == "$value" ]]; then
    is_found=true
    break
  fi
done

if ! $is_found ; then
  echo "invalid method"
  exit 0
fi

## input vars
SERVICE_NAME="$2"
VOL_PW="$3"


forklift-image-build() {
FORKLIFT_DIR="${HOME}/image-builders/forklift"

mkdir -p ${FORKLIFT_DIR}

pushd ${FORKLIFT_DIR}

cat << EOF > Dockerfile
FROM alpine:latest

# Install bash
RUN apk update \
  && apk add --no-cache bash shadow vim \
  7zip tar xz zip unzip \
  gzip rsync rsync-openrc openssh \
  iputils bind-tools curl ca-certificates \
  jq yq miller

# just for reference:
# start sshd service
# rc-service sshd start
# rc-update add sshd

# Optional: Set bash as the default shell for the root user
#RUN sed -i 's/\/root:\/bin\/ash/\/root:\/bin\/bash/' /etc/passwd
RUN chsh -s /bin/bash root

# userspace folder
RUN mkdir /home/1000 ; chown 1000:1000 /home/1000

# Optional: Set bash as the default command when running the container
CMD ["/bin/bash"]
EOF

docker build --no-cache -t local/forklift:latest .
popd
}


get-images() {
    local COMPOSE_FILE=$1
    docker run --rm -it \
      -v ${COMPOSE_FILE}:/docker-compose.yml:ro \
      local/forklift yq -r '.services[].image?' "/docker-compose.yml" | tr -d '\r' | xargs
}

get-service-vols() {
    local COMPOSE_FILE=$1
    docker run --rm -it \
      -v ${COMPOSE_FILE}:/docker-compose.yml:ro \
       local/forklift yq -r '.volumes | keys[]?' "/docker-compose.yml" | tr -d '\r' | xargs
}


####
# build forklift archive
build-forklift() {
local TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
local ARCH_FOLDER="${HOME}/temp"
local TS_PATH="${ARCH_FOLDER}/${SERVICE_NAME}/${TIMESTAMP}"
local USER_PERM="`id -u`:`id -g`"
local SERVICE_COMPOSE=$(docker compose ls | grep ${SERVICE_NAME} | awk '{print $3}')
local SERVICE_DIR=$(dirname ${SERVICE_COMPOSE})

#echo kill-switch
#exit 0

mkdir -p ${TS_PATH}
pushd ${SERVICE_DIR}

## get and save images
SERVICE_IMAGES=$(get-images $SERVICE_COMPOSE)
docker image save -o ${TS_PATH}/${SERVICE_NAME}_images.tar ${SERVICE_IMAGES}

## save service folder content
tar -czvf ${TS_PATH}/${SERVICE_NAME}-service-folder.tar.gz -C ${SERVICE_DIR%/*} ${SERVICE_DIR##*/}

## get and save vols
SERVICE_VOLS=$(get-service-vols $SERVICE_COMPOSE)
 
for svol in ${SERVICE_VOLS}
do
# compress contents of volume
COMP="/backup-dst/${svol}-archive.7z"

docker run --rm -t \
  -v ${svol}:/backup-src:ro \
  -v ${TS_PATH}:/backup-dst \
  local/forklift bash -c "7z a ${COMP} -p${VOL_PW} /backup-src/* ; chown ${USER_PERM} ${COMP} ; chmod 600 ${COMP}" 
done
popd

tar -czvf ${ARCH_FOLDER}/${SERVICE_NAME}_${TIMESTAMP}-with-images.tar.gz -C ${ARCH_FOLDER} ${SERVICE_NAME}/${TIMESTAMP}
ls -alh ${ARCH_FOLDER}
}


####
# deploy forklift service
deploy-forklift() {
local TIMESTAMP="$1"
local ARCH_FOLDER="${HOME}/temp"
local TS_PATH="${ARCH_FOLDER}/${SERVICE_NAME}/${TIMESTAMP}"
local SERVICE_PARENT_FOLDER="${HOME}/services"
local SERVICE_DIR="${SERVICE_PARENT_FOLDER}/${SERVICE_NAME}"

#echo kill-switch
#exit 0

mkdir -p ${SERVICE_PARENT_FOLDER}

pushd ${ARCH_FOLDER}
tar xzvf ${SERVICE_NAME}_${TIMESTAMP}-with-images.tar.gz

pushd ${SERVICE_NAME}/${TIMESTAMP}

# image
find ./ -type f -iname *_images.tar -exec docker image load -i {} \;

# service folder content
#ORIG_SERVICE_NAME=$(find ./ -type f -iname *-service-folder.tar.gz -exec tar -zxvf {} --overwrite -C ${SERVICE_PARENT_FOLDER} \; |head -n1 | tr -d '/')
#pushd ${SERVICE_PARENT_FOLDER}

find ./ -type f -iname *-service-folder.tar.gz -exec tar -zxvf {} -C ${SERVICE_PARENT_FOLDER} \;

pushd ${SERVICE_DIR}

SERVICE_COMPOSE=${SERVICE_DIR}/docker-compose.yml

# vols
SERVICE_VOLS=$(get-service-vols ${SERVICE_COMPOSE})
 
for svol in ${SERVICE_VOLS}
do
echo "creating docker volume ${svol}"
docker volume rm ${svol}
docker volume create ${svol}
# compress contents of volume
COMP="/backup-src/${svol}-archive.7z"

docker run --rm -t \
  -v ${svol}:/backup-dst \
  -v ${TS_PATH}:/backup-src:ro \
  local/forklift bash -c "7z x -y ${COMP} -p${VOL_PW} -o/backup-dst/" 
done

popd ; popd ; popd
}


case "${FORKLIFT_METHOD}" in
  "image-build")
    forklift-image-build
    ;;
  "build")
    build-forklift
    ;;
  "deploy")
    echo deploy
    if [ -z $4 ]; then
      echo "require timestamp value"
      exit 0
    fi
    deploy-forklift $4
    ;;
  *)
    echo "no actions"
    exit 0
    ;;
esac

