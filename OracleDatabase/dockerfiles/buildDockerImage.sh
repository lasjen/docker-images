#!/bin/bash
#set -x
# 
# Since: April, 2016
# Author: gerald.venzl@oracle.com
# Description: Build script for building Oracle Database Docker images.
# 
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
# 
# Copyright (c) 2014-2016 Oracle and/or its affiliates. All rights reserved.
# 

# -----------------------------------------------------
# Variables and parameters
# -----------------------------------------------------
SOURCE_DIR="`dirname $PWD`/install_files"
VOLUME_PATH="/opt/oracle/oradata"
HOST_PORT=8081

ENTERPRISE=0
STANDARD=0
EXPRESS=0
VERSION="12.1.0.2"
SKIPMD5=0
DOCKEROPS=""
USE_VOLUME=0

# -----------------------------------------------------
# Functions
# -----------------------------------------------------
usage() {
cat << EOF

Usage: buildDockerImage.sh -v [version] -I <host ip> -d <source directory> [-e | -s | -x] [-i] 
Builds a Docker Image for Oracle Database.
  
Parameters:
   -v: version to build
       Choose one of: $(for i in $(ls -d */); do echo -n "${i%%/}  "; done)
   -e: creates image based on 'Enterprise Edition'
   -s: creates image based on 'Standard Edition 2'
   -x: creates image based on 'Express Edition'
   -i: ignores the MD5 checksums
   -V: creates an oradata volume
   -I: Ip address for your host machine 
   -d: Set source directory (which contains install files) (default: $SOURCE_DIR)

* select one edition only: -e, -s, or -x

LICENSE CDDL 1.0 + GPL 2.0

Copyright (c) 2014-2016 Oracle and/or its affiliates. All rights reserved.

EOF
exit 0
}

# Validate packages
checksumPackages() {
  md5sum -c Checksum.$EDITION
  if [ "$?" -ne 0 ]; then
    echo "INFO: MD5 for required packages to build this image did not match!"
    echo "INFO: Make sure to download missing files in folder $VERSION."
    exit $?
  fi
}

# Proxy settings
setProxy() {
  PROXY_SETTINGS=""
  if [ "${http_proxy}" != "" ]; then
    PROXY_SETTINGS="$PROXY_SETTINGS --build-arg=\"http_proxy=${http_proxy}\""
  fi

  if [ "${https_proxy}" != "" ]; then
    PROXY_SETTINGS="$PROXY_SETTINGS --build-arg=\"https_proxy=${https_proxy}\""
  fi

  if [ "${ftp_proxy}" != "" ]; then
    PROXY_SETTINGS="$PROXY_SETTINGS --build-arg=\"ftp_proxy=${ftp_proxy}\""
  fi

  if [ "${no_proxy}" != "" ]; then
    PROXY_SETTINGS="$PROXY_SETTINGS --build-arg=\"no_proxy=${no_proxy}\""
  fi

  if [ "$PROXY_SETTINGS" != "" ]; then
    echo "INFO: Proxy settings were found and will be used during build."
  else 
    echo "INFO: No proxy settings found."
  fi
}

prepareBuild() {
  echo "Preparing the build ..."

  echo "--> Reading arguments."
  readArguments $@

  echo "--> Setting version" 
  setVersion
 
  echo "--> Setting proxy"
  setProxy

  if [ -z "$HOST_IP" ]; then
    echo "INFO: The option -I with an IP adress must be specified"
    exit 1
  fi

  if [ ! "$SKIPMD5" -eq 1 ]; then
    echo "--> Checking if required packages are present and valid..."
    checksumPackages
  else
    echo "INFO: Ignored MD5 checksum."
  fi
}

printVariables() {
  echo ""
  echo "Buiding image based on following choices:"
  echo "--> Image:    $IMAGE_NAME"
  echo "--> Host:     $HOST_IP"
  echo "--> Editon:   $EDITION"
  echo "--> Version:  $VERSION"
  echo ""
}

# Parse arguments
readArguments() {
  local OPTIND
  while getopts "hesxiVv:I:d:" optname; do
    case "$optname" in
      "h")
        usage
        ;;
      "i")
        SKIPMD5=1
        ;;
      "e")
        ENTERPRISE=1
        ;;
      "s")
        STANDARD=1
        ;;
      "x")
        EXPRESS=1
        ;;
      "v")
        VERSION="$OPTARG"
        ;;
      "V")
        USE_VOLUME=1
        ;;
      "I")
        HOST_IP="$OPTARG"
        ;;
      "d")
        SOURCE_DIR="$OPTARG"
        ;;
      *)
      # Should not occur
        echo "Unknown error while processing options inside buildDockerImage.sh"
        ;;
    esac
  done
}

# Which Edition should be used?
setVersion() {
  if [ $((ENTERPRISE + STANDARD + EXPRESS)) -gt 1 ]; then
    usage
  elif [ $ENTERPRISE -eq 1 ]; then
    EDITION="ee"
  elif [ $STANDARD -eq 1 ]; then
    EDITION="se2"
  elif [ $EXPRESS -eq 1 ] && [ "$VERSION" = "12.1.0.2" ]; then
    echo "Version 12.1.0.2 does not have Express Edition available."
    exit 1
  else
    EDITION="xe";
    DOCKEROPS="--shm-size=1G";
  fi
}

# -----------------------------------------------------
# MAIN section
# -----------------------------------------------------
if [ "$#" -eq 0 ]; then usage; fi

# Prepare
prepareBuild $@

# Oracle Database Image Name
IMAGE_NAME="oracle/database:$VERSION-$EDITION"

# Print Variables
printVariables

# Go into version folder
cd $VERSION

# ################## #
# Start HTTP server  #
# ################## #
echo "Starting a HTTP file server on $HOST_IP:80"
docker run -dit --name temp-ora-file-serv -v $SOURCE_DIR:/usr/local/apache2/htdocs/ -p $HOST_PORT:80 httpd:2.4 || {
  echo "INFO HTTP file server allready running."
}

# ################## #
# BUILDING THE IMAGE #
# ################## #
echo "----------------------------------------------------------------"
echo "Building image '$IMAGE_NAME' ..."
BUILD_START=$(date '+%s')

# BUILD THE IMAGE (replace all environment variables)
docker build --force-rm=true --no-cache=true --build-arg HOST_URL=$HOST_IP:$HOST_PORT $DOCKEROPS $PROXY_SETTINGS -t $IMAGE_NAME -f Dockerfile.$EDITION . || {
  echo "There was an error building the image."
  exit 1
}

# If USE_VOLUME is set - build new image
if [  "$USE_VOLUME" -eq 1 ]; then
  cat << EOF > Dockerfile.vol
  FROM $IMAGE_NAME
  VOLUME ["$VOLUME_PATH"]
EOF

  docker build --force-rm=true --no-cache=true $DOCKEROPS $PROXY_SETTINGS -t $IMAGE_NAME -f Dockerfile.vol . || {
    echo "There was an error building the image."
  exit 1
}
  rm -f Dockerfile.vol
fi

BUILD_END=$(date '+%s')
BUILD_ELAPSED=`expr $BUILD_END - $BUILD_START`

# ################## #
# Stop HTTP server  #
# ################## #
echo "Cleaning: Stoping the HTTP file server on $HOST_IP:80"
docker stop temp-ora-file-serv && docker rm temp-ora-file-serv || {
  echo "Failed stoping the HTTP file server"
}

if [ `docker images |grep "$IMAGE_NAME " | wc -l` -eq 0 ]; then
  echo "";
  echo "Oracle Database Docker Image for '$EDITION' version $VERSION is ready to be extended:"
  echo "";
  echo "   --> $IMAGE_NAME"
  echo "";
  echo "Build completed in $BUILD_ELAPSED seconds."
else
  echo "Oracle Database Docker Image was NOT successfully created. Check the output and correct any reported problems with the docker build operation."
fi

