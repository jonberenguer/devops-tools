# devops-tools

## overview
Collection of personalized scripts for devops related task.

*Use with caution


## forklift-cli.sh
This script is used to build a package of a running docker service. The compress package can then be migrated and deployed to another host.
Please use with caution will remove specific existing volumes when package is deployed.

Package will contain:
- service image
- service folder
- service volumes (compressed with a password)

``` bash
# usage:
# build local image, the container contains all the necessary tools
bash forklift-cli.sh image-build

# to build package
bash forklift-cli.sh build active-service-name compress_password

# file output: active-service-name_timestamp-value-with-images.tar.gz

# to deploy package
bash forklift-cli.sh build active-service-name compress_password timestamp-value
```

## To do
- add more error handling
- have option to just backup service folder and service volumes
